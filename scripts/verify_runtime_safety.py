"""Runtime ownership regressions with isolated foreground commands and no windows."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))
(ROOT / 'work').mkdir(exist_ok=True)


def distinct_ports():
    with socket.socket() as first, socket.socket() as second:
        first.bind(('127.0.0.1', 0))
        second.bind(('127.0.0.1', 0))
        return first.getsockname()[1], second.getsockname()[1]


def alive(pid):
    state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
    return bool(state) and 'Z' not in state


def until(predicate, message, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(message)


with tempfile.TemporaryDirectory(prefix='Runtime ownership ', dir=ROOT / 'work') as folder:
    base = Path(folder)
    project = base / 'project'; project.mkdir()
    state = base / 'state'
    port, outside_port = distinct_ports()
    child_file = base / 'child.pid'
    (project / 'app.py').write_text(
        'import http.server,pathlib,subprocess,sys\n'
        'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(180)"],start_new_session=True)\n'
        f'pathlib.Path({str(child_file)!r}).write_text(str(child.pid))\n'
        'http.server.HTTPServer.allow_reuse_address=True\n'
        f'http.server.HTTPServer(("127.0.0.1",{port}),http.server.SimpleHTTPRequestHandler).serve_forever()\n'
    )
    (project / 'package.json').write_text('{}')
    environment = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    outsiders = []
    additional_ids = []
    fixture_pids = set()
    fixture_groups = set()

    def cli(*args, check=True):
        return subprocess.run([BINARY, *args], env=environment, capture_output=True, text=True, timeout=45, check=check)

    def listening(number):
        try:
            with socket.create_connection(('127.0.0.1', number), timeout=.1):
                return True
        except OSError:
            return False

    def start_outsider():
        with (base / 'outsider.log').open('w+') as log:
            process = subprocess.Popen(
                [sys.executable, '-m', 'http.server', str(outside_port), '--bind', '127.0.0.1'],
                cwd=project, stdout=subprocess.DEVNULL, stderr=log,
            )
            outsiders.append(process)

            def ready():
                if process.poll() is not None:
                    log.seek(0)
                    raise AssertionError(f'Independent command exited {process.returncode}: {log.read()}')
                return listening(outside_port)

            until(ready, 'Independent same-directory command did not start')
        return process

    def wait_for_managed_server():
        log = state / (identifier + '.log')

        def ready():
            if listening(port):
                return child_file.exists()
            states = [json.loads(file.read_text()) for file in (state / 'development').glob('*.json')]
            if any(session['phase'] == 'failed' for session in states):
                details = log.read_text() if log.exists() else str(states)
                raise AssertionError('Managed command failed:\n' + details)
            return False

        try:
            until(ready, 'Managed command did not start')
        except AssertionError as error:
            details = log.read_text() if log.exists() else 'No managed command log'
            listener = subprocess.run(['/usr/sbin/lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN'],
                                      capture_output=True, text=True).stdout.strip()
            raise AssertionError(f'{error}\nChild PID file exists: {child_file.exists()}\n'
                                 f'Loopback listener: {listener or "none"}\n{details}') from error

    identifier = cli('--add-project', str(project), '--command', shlex.quote(sys.executable) + ' -u app.py').stdout.strip()
    try:
        for command in ('python3 -m http.server 0 &', 'nohup python3 -m http.server 0'):
            other = base / ('detached-' + str(len(outsiders))); other.mkdir(exist_ok=True)
            detached = cli('--add-project', str(other), '--command', command).stdout.strip()
            result = cli('--start-project', detached, check=False)
            assert result.returncode != 0 and '前台' in result.stderr, result.stderr
            cli('--remove-project', detached)
        cli('--start-project', identifier)
        wait_for_managed_server()
        fixture_pids.add(int(child_file.read_text()))
        outsider = start_outsider()
        cli('--stop-project', identifier)
        until(lambda: not listening(port), 'Owned command was not stopped')
        assert listening(outside_port) and outsider.poll() is None, 'Stop affected an independent command in the same folder'
        assert cli('--start-project', identifier, check=False).returncode != 0
        assert listening(outside_port), 'Ordinary start must never close an existing runtime'
        menu = next(row for row in json.loads(cli('--menu-json').stdout) if row.get('value') == str(project))
        assert any(row.get('action') == 'stopProject:' and row['title'] == '停止' for row in menu['items'])
        assert '其他应用' not in json.dumps(menu, ensure_ascii=False)
        cli('--restart-project', identifier)
        until(lambda: listening(port) and not listening(outside_port), 'Explicit restart did not replace the current project runtime')
        outsider.wait(timeout=5)
        cli('--stop-project', identifier)
        until(lambda: not listening(port), 'Restarted runtime did not stop')
        outsider = start_outsider()
        cli('--stop-project', identifier)
        outsider.wait(timeout=5)
        assert not listening(outside_port)
        print('PASS: foreground contract, explicit control regardless of launch source, duplicate protection and same-directory independent-process isolation')

        cli('--start-project', identifier)
        until(lambda: listening(port), 'Second managed command did not start')
        run = json.loads(next(state.glob(identifier + '.target-*.run.json')).read_text())
        key = hashlib.sha256((str(project) + '\n' + run['targetID']).encode()).hexdigest()
        session_file = state / 'development' / (key + '.json')
        until(lambda: session_file.exists() and json.loads(session_file.read_text())['phase'] == 'watching', 'Session identity was not recorded')
        session = json.loads(session_file.read_text())
        fixture_pids.update((session['supervisor']['pid'], session['child']['pid'], int(child_file.read_text())))
        fixture_groups.add(session['child']['group'])
        os.kill(session['supervisor']['pid'], signal.SIGKILL)
        until(lambda: not alive(run['pid']), 'Launcher did not exit after supervisor crash')
        assert listening(port), 'Crash fixture did not retain its child'
        cli('--stop-project', identifier, '--target', run['targetID'])
        until(lambda: not listening(port) and not alive(int(child_file.read_text())), 'Recorded orphan command or descendant survived stop')
        print('PASS: abrupt supervisor exit retains exact ownership; stop cleans reparented command and detached descendant')

        for exit_code in (0, 1):
            script_project = base / ('script-exit-' + str(exit_code)); script_project.mkdir()
            marker = base / ('script-finished-' + str(exit_code))
            (script_project / 'main.py').write_text(f'import pathlib,sys\npathlib.Path({str(marker)!r}).write_text("done")\nsys.exit({exit_code})\n')
            script_id = cli('--add-project', str(script_project)).stdout.strip()
            additional_ids.append(script_id)
            cli('--start-project', script_id)
            until(marker.exists, 'Ordinary Python script did not execute')
            record = json.loads(next(state.glob(script_id + '.target-*.run.json')).read_text())
            digest = hashlib.sha256((str(script_project) + '\n' + record['targetID']).encode()).hexdigest()
            script_state = state / 'development' / (digest + '.json')
            if exit_code == 0:
                until(lambda: not alive(record['pid']), 'Successful one-shot script kept a supervisor running')
                assert not script_state.exists(), 'Successful script retained a failed/watching state'
                assert '运行完成' in (state / (script_id + '.log')).read_text()
            else:
                until(lambda: script_state.exists() and json.loads(script_state.read_text())['phase'] == 'failed', 'Nonzero script exit was not reported as failed')
                cli('--stop-project', script_id)
        print('PASS: successful ordinary scripts finish normally; nonzero exits remain visible and stoppable')

    finally:
        cli('--stop-project', identifier, check=False)
        for script_id in additional_ids:
            cli('--stop-project', script_id, check=False)
        for process in outsiders:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)
        if child_file.exists():
            fixture_pids.add(int(child_file.read_text()))
        # Reap only members of the recorded fixture groups whose cwd is this
        # temporary project, even if an assertion interrupts ownership cleanup.
        process_table = subprocess.run(['ps', '-U', str(os.getuid()), '-o', 'pid=,pgid='], capture_output=True, text=True).stdout
        for line in process_table.splitlines():
            fields = line.split()
            if len(fields) != 2 or int(fields[1]) not in fixture_groups:
                continue
            pid = int(fields[0])
            cwd = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True).stdout
            if any(row == 'n' + str(project) for row in cwd.splitlines()):
                fixture_pids.add(pid)
        for pid in fixture_pids:
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
