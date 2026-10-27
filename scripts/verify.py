"""Exercise discovery with real local processes, without opening any UI."""
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = root / ".build/release/DevBar"
subprocess.run([str(binary), "--self-test"], check=True)
(root / "work").mkdir(exist_ok=True)

def scan():
    return json.loads(subprocess.check_output([str(binary), "--scan-json"], timeout=30))

with tempfile.TemporaryDirectory(prefix="DevBar fixture ", dir=root / "work") as folder:
    project = pathlib.Path(folder)
    (project / "pyproject.toml").write_text('[project]\nname="devbar-fixture"\nversion="0.0.0"\n')
    native_dir = project / ".build/debug"
    native_dir.mkdir(parents=True)
    source = project / "worker.c"
    source.write_text("#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n")
    native = native_dir / "fixture-native"
    subprocess.run(["/usr/bin/clang", str(source), "-o", str(native)], check=True)
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        port = available.getsockname()[1]
    children = []
    try:
        children.append(subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"], cwd=folder, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        children.append(subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], cwd=folder))
        # Native binaries can be launched with a working directory outside their source tree.
        children.append(subprocess.Popen([str(native)], cwd="/"))
        helper = project / "agentation-mcp.py"
        helper.write_text('import http.server, sys, time\nif len(sys.argv)>1: http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),http.server.SimpleHTTPRequestHandler).serve_forever()\nelse: time.sleep(120)\n')
        with socket.socket() as available:
            available.bind(('127.0.0.1', 0))
            helper_port = available.getsockname()[1]
        children.append(subprocess.Popen([sys.executable, str(helper), str(helper_port)], cwd=folder, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        projects = scan()
        matches = [p for p in projects if p["path"] == folder]
        assert len(matches) == 1, "Project must be grouped once"
        fixture = matches[0]
        assert port in [listener["port"] for listener in fixture["listeners"]]
        assert port in [listener["port"] for listener in fixture["entryPoints"]]
        assert next(p for p in fixture['processes'] if p['pid'] == children[-1].pid)['category'] == 'tool'
        assert helper_port in [listener['port'] for listener in fixture['auxiliaryServices']]
        assert helper_port not in [listener['port'] for listener in fixture['entryPoints']]
        assert {child.pid for child in children}.issubset({p["pid"] for p in fixture["processes"]}), "Must include web, portless script and native binary"
        print("PASS: real Web server, portless script, native binary, path with spaces and project grouping")
        menus = json.loads(subprocess.check_output([str(binary), '--menu-json'], timeout=30))
        menu = next(row['items'] for row in menus if row['title'] == project.name)
        assert not any('PID' in row['title'] for row in menu), 'PIDs must be collapsed'
        entry = next(row for row in menu if row['title'] == '打开网页')
        assert entry['action'] == 'openURL:' and entry['value'] == f'http://localhost:{port}'
        more = next(row['items'] for row in menu if row['title'] == '更多')
        assert next(row for row in more if row['title'] == '复制地址')['action'] == 'copyURL:'
        assert [row['title'] for row in menu if row.get('action') and row.get('action') != 'submenuAction:'] == ['打开网页', '停止项目进程']
        assert not any('辅助服务' in row['title'] or '进程详情' in row['title'] for row in menu)
        assert not any('更新于' in row['title'] for row in menus)
        print('PASS: compact native menu exposes open/stop; copy and management remain available in More')
    finally:
        for child in children:
            child.terminate()
        for child in children:
            child.wait(timeout=5)
    assert all(p["path"] != folder for p in scan()), "Stopped processes must disappear"
    print("PASS: stopped projects disappear")
    helper_process = subprocess.Popen([sys.executable, str(helper)], cwd=folder)
    try:
        time.sleep(0.1)
        assert all(p['path'] != folder for p in scan()), 'Tools alone must not keep a project running'
        print('PASS: auxiliary classification and tool-only project exclusion')
    finally:
        helper_process.terminate()
        helper_process.wait(timeout=5)
