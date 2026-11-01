"""Verify the production store, launcher, stopper and NSMenu without opening UI."""
import json
import os
import pathlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = os.environ.get('DEVBAR_TEST_BINARY', str(root / '.build/release/DevBar'))
(root / 'work').mkdir(exist_ok=True)

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def listening(number):
    try:
        with socket.create_connection(('127.0.0.1', number), timeout=0.1):
            return True
    except OSError:
        return False

def until(predicate, message):
    for _ in range(160):
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='Lifecycle ', dir=root / 'work') as folder:
    base = pathlib.Path(folder)
    project = base / 'Project with spaces'
    project.mkdir()
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state))
    children = []
    main_port, auxiliary_port, other_port = port(), port(), port()
    script = project / 'app.py'
    script.write_text('''import http.server, pathlib, subprocess, sys
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'], start_new_session=True)
pathlib.Path('child.pid').write_text(str(child.pid))
print('DevBar lifecycle fixture', flush=True)
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), http.server.SimpleHTTPRequestHandler).serve_forever()
''')
    helper = project / 'agentation-mcp.py'
    helper.write_text('import http.server,sys\nhttp.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),http.server.SimpleHTTPRequestHandler).serve_forever()\n')
    command = f'{shlex.quote(sys.executable)} -u {shlex.quote(str(script))} {main_port}'

    def cli(*args, check=True):
        return subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=35, check=check)

    def menu_items():
        rows = json.loads(cli('--menu-json').stdout)
        return next(row['items'] for row in rows if row['title'] == 'Fixture')

    def flatten(rows):
        return [node for row in rows for node in [row, *flatten(row.get('items', []))]]

    def new_run():
        runner = subprocess.Popen([binary, '--start-project', ident, '--wait'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(runner)
        assert runner.stdout.readline().strip() == 'Started', 'Launcher must report start'
        until(lambda: listening(main_port), 'Web service failed to start')
        return runner

    try:
        automatic = base / 'Automatic project'
        automatic.mkdir()
        (automatic / 'package.json').write_text(json.dumps({'scripts': {'dev': 'touch AUTO_SHOULD_NOT_RUN'}, 'packageManager': 'pnpm@9.0.0'}))
        (automatic / 'bun.lock').write_text('')
        automatic_id = cli('--add-project', str(automatic)).stdout.strip()
        detected = next(p for p in json.loads(cli('--list-projects').stdout) if p['id'] == automatic_id)
        assert detected['command'] == 'pnpm run dev', 'Declared package manager must override stale lockfiles'
        assert not (automatic / 'AUTO_SHOULD_NOT_RUN').exists(), 'Detection must not execute project scripts'
        cli('--remove-project', automatic_id)
        (automatic / 'package.json').write_text(json.dumps({'scripts': {'dev': '  ', 'start': 'node server.js'}, 'packageManager': 'npm@10.0.0'}))
        automatic_id = cli('--add-project', str(automatic)).stdout.strip()
        detected = next(p for p in json.loads(cli('--list-projects').stdout) if p['id'] == automatic_id)
        assert detected['command'] == 'npm run start', 'Empty scripts must not be selected'
        cli('--remove-project', automatic_id)
        print('PASS: automatic command detection, package manager precedence and no script execution during add')

        ident = cli('--add-project', str(project), '--command', command, '--name', 'Fixture').stdout.strip()
        assert json.loads(cli('--list-projects').stdout)[0]['id'] == ident
        duplicate = cli('--add-project', str(project), '--command', command, check=False)
        assert duplicate.returncode != 0
        assert any(row.get('action') == 'startProject:' for row in menu_items())
        print('PASS: persisted project, duplicate protection, stopped menu and run action')

        auxiliary = subprocess.Popen([sys.executable, str(helper), str(auxiliary_port)], cwd=project, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        other = subprocess.Popen([sys.executable, '-m', 'http.server', str(other_port), '--bind', '127.0.0.1'], cwd=base, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.extend([auxiliary, other])
        until(lambda: listening(auxiliary_port) and listening(other_port), 'Independent services failed to start')
        runner = new_run()
        duplicate = cli('--start-project', ident, check=False)
        assert duplicate.returncode != 0
        items = menu_items()
        assert any(row.get('action') == 'stopProject:' for row in items)
        assert any(row.get('action') == 'showLog:' for row in flatten(items))
        assert any(row['title'] == '停止' for row in items)
        assert not any(row['title'] in ['查看日志', '设置…', '移除'] for row in items)
        cli('--stop-project', ident)
        runner.wait(timeout=10)
        until(lambda: not listening(main_port), 'Managed server still listening')
        assert listening(auxiliary_port) and listening(other_port), 'Stopping a project must preserve independent services'
        child_pid = int((project / 'child.pid').read_text())
        child_status = subprocess.run(['ps', '-p', str(child_pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
        assert not child_status or 'Z' in child_status, 'Descendant must stop'
        assert 'DevBar lifecycle fixture' in (state / f'{ident}.log').read_text()
        assert any(row.get('action') == 'startProject:' for row in menu_items())
        print('PASS: launch, logs, no duplicate run, managed group stop, descendant cleanup and auxiliary isolation')

        runner = new_run()
        cli('--stop-project', ident)
        runner.wait(timeout=10)
        print('PASS: stopped project can run again')

        external = subprocess.Popen([sys.executable, str(script), str(main_port)], cwd=project, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        children.append(external)
        until(lambda: listening(main_port), 'External fixture failed to start')
        items = menu_items()
        assert any(row.get('action') == 'stopProject:' for row in items)
        assert not any('其他应用' in row['title'] for row in items)
        cli('--stop-project', ident)
        external.wait(timeout=10)
        assert not listening(main_port) and listening(auxiliary_port) and listening(other_port)
        print('PASS: externally started project stops from the same control while MCP and unrelated services survive')

        stale = {'token': 'stale-test', 'pid': other.pid, 'signature': 'not-this-process', 'startedAt': 0}
        (state / f'{ident}.run.json').write_text(json.dumps(stale))
        cli('--stop-project', ident, check=False)
        assert listening(other_port), 'Stale PID state must never stop another process'
        print('PASS: stale process identity cannot stop an unrelated service')

        failed = base / 'failed'
        failed.mkdir()
        bad_id = cli('--add-project', str(failed), '--name', 'Failure', '--command', 'devbar_missing_command_9471').stdout.strip()
        cli('--start-project', bad_id)
        import hashlib
        record = json.loads(next(state.glob(f'{bad_id}.target-*.run.json')).read_text())
        development_file = state / 'development' / (hashlib.sha256((str(failed)+'\n'+record['targetID']).encode()).hexdigest()+'.json')
        until(lambda: development_file.exists() and json.loads(development_file.read_text())['phase'] == 'failed', 'Development failure not reported')
        assert 'devbar_missing_command_9471' in (state / f'{bad_id}.log').read_text()
        cli('--stop-project', bad_id)
        print('PASS: failed development command retains log and can be stopped while waiting for edits')

        cli('--remove-project', ident)
        assert project.exists() and script.exists()
        assert all(p['id'] != ident for p in json.loads(cli('--list-projects').stdout))
        config_file = state / 'projects.json'
        config_file.write_text('{invalid')
        assert cli('--add-project', str(project), '--command', command, check=False).returncode != 0
        assert config_file.read_text() == '{invalid'
        print('PASS: removal preserves source; malformed configuration is not overwritten')
    finally:
        # All signals in this test are restricted to fixture processes.
        for record_path in state.glob('*.run.json'):
            record = json.loads(record_path.read_text())
            try:
                if os.getpgid(record['pid']) == record['pid']:
                    os.killpg(record['pid'], signal.SIGTERM)
            except ProcessLookupError:
                pass
        for path in [project / 'child.pid']:
            if path.exists():
                try:
                    os.kill(int(path.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for child in children:
            if child.poll() is None:
                child.terminate()
        for child in children:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
