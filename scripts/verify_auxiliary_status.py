"""Auxiliary processes alone must not keep a project running; no app or browser UI."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))
(ROOT / 'work').mkdir(exist_ok=True)

with tempfile.TemporaryDirectory(prefix='Auxiliary status ', dir=ROOT / 'work') as folder:
    base = Path(folder)
    project = base / 'Project'; project.mkdir()
    (project / 'package.json').write_text('{"scripts":{"dev":"python3 -m http.server"}}')
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / 'state'), DEVBAR_HEADLESS='1')
    processes = []

    def cli(*args):
        return subprocess.run([BINARY, *map(str, args)], env=env, capture_output=True,
                              text=True, check=True, timeout=45).stdout

    def scan():
        return next((p for p in json.loads(cli('--scan-json')) if p['path'] == str(project)), None)

    def launch(*args):
        child = subprocess.Popen(list(map(str, args)), cwd=project, start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        processes.append(child)
        return child

    def until(predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.05)
        raise AssertionError('Fixture startup timed out')

    def listening(port):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1): return True
        except OSError:
            return False

    # Real native process names exercise classification of binaries, rather
    # than only interpreter command strings. They create no windows.
    source = base / 'sleeper.c'
    source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
    native = base / 'sleeper'
    subprocess.run(['cc', str(source), '-o', str(native)], check=True, capture_output=True)
    (project / 'bin').mkdir()
    mcp = project / 'mcp_server.py'
    mcp.write_text(
        'import http.server,pathlib,subprocess,sys\n'
        'subprocess.Popen([sys.executable,"worker.py"])\n'
        'server=http.server.HTTPServer(("127.0.0.1",0),http.server.SimpleHTTPRequestHandler)\n'
        'pathlib.Path("tool-port").write_text(str(server.server_port))\n'
        'server.serve_forever()\n')
    (project / 'worker.py').write_text('import time\ntime.sleep(180)\n')
    (project / 'mcp.mjs').write_text('setInterval(() => {}, 1000);\n')
    try:
        python_tool = launch(sys.executable, mcp)
        launch('node', project / 'mcp.mjs')
        for name, flags in [('clangd', []), ('rust-analyzer', []), ('Electron', ['--type=gpu-process']),
                            ('Electron Helper (Renderer)', []), ('chrome_crashpad_handler', [])]:
            executable = project / 'bin' / name
            shutil.copy2(native, executable)
            launch(executable, *flags)
        until(lambda: (project / 'tool-port').exists())
        tool_port = int((project / 'tool-port').read_text())
        assert scan() is None, 'MCP, language servers or orphan Electron helpers impersonated a running project'
        print('PASS: Python/Node MCP, tool descendants, native language servers and orphan Electron helpers do not count as running')

        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        webpage = launch(sys.executable, '-m', 'http.server', port, '--bind', '127.0.0.1')
        until(lambda: listening(port))
        result = scan()
        assert result and [entry['port'] for entry in result['entryPoints']] == [port], result
        assert next(p for p in result['portDetails'] if p['listener']['port'] == tool_port)['role'] == 'tool'
        tool_ids = {p.pid for p in processes if p != webpage}
        assert not tool_ids.intersection(p['pid'] for p in result['controlProcesses'])
        identifier = cli('--add-project', project, '--command', '').strip()
        cli('--stop-project', identifier)
        webpage.wait(timeout=10)
        assert all(p.poll() is None for p in processes if p != webpage), 'Stopping the webpage terminated a tool/helper'
        assert listening(tool_port) and scan() is None
        print('PASS: real webpage is detected and stopped independently; tool ports and processes remain protected')
    finally:
        for child in processes:
            try: os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError: pass
        for child in processes:
            child.wait(timeout=10)
