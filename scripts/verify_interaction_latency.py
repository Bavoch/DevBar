"""Native panel actions under a 60-project load; no windows or browsers shown."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
binary = os.environ.get('DEVBAR_TEST_BINARY', str(root / '.build/release/DevBar'))


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.1):
            return True
    except OSError:
        return False


with tempfile.TemporaryDirectory(prefix='Panel latency ', dir=root / 'work') as folder:
    base = Path(folder)
    project = base / 'NPM development'
    project.mkdir()
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    ports = [free_port(), free_port()]
    (project / 'server.cjs').write_text(
        "require('node:http').createServer((q,s)=>s.end('development')).listen(Number(process.argv[2]),'127.0.0.1');\n")
    (project / 'package.json').write_text(json.dumps({'scripts': {
        'dev': f'node server.cjs {ports[0]}',
        'dev:backend': f'node server.cjs {ports[1]}',
    }}))

    def cli(*args, check=True):
        return subprocess.run([binary, *args], env=env, capture_output=True, text=True, check=check, timeout=60)

    def until(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.1)
        raise AssertionError('development process state timed out')

    ident = cli('--add-project', str(project)).stdout.strip()
    rows = json.loads((state / 'projects.json').read_text())
    for index in range(59):
        fixture = base / f'Project {index}'
        fixture.mkdir()
        (fixture / 'package.json').write_text(json.dumps({'scripts': {'dev': 'node app.js', 'dev:backend': 'node backend.js'}}))
        rows.append(dict(id=str(uuid.uuid4()), name=fixture.name, path=str(fixture), command='npm run dev'))
    (state / 'projects.json').write_text(json.dumps(rows))
    try:
        for target, port in zip(('dev', 'dev:backend'), ports):
            cli('--start-project', ident, '--target', target)
            until(lambda: listening(port))
        for target, port in zip(('dev', 'dev:backend'), ports):
            result = cli('--self-test-interaction-latency', '--stop-fixture', str(project), '--target', target)
            print(result.stdout, end='', flush=True)
            assert not listening(port), f'{target} listener survived the panel stop action'
            if target == 'dev':
                assert listening(ports[1]), 'stopping frontend also stopped backend'
        assert any(row['id'] == ident for row in json.loads(cli('--list-projects').stdout))
        print('PASS: actual npm run dev sessions, 60 project controls, independent targets, final stopped row and persisted configuration', flush=True)
    finally:
        for target in ('dev', 'dev:backend'):
            cli('--stop-project', ident, '--target', target, check=False)
        for file in state.glob('*.run.json'):
            record = json.loads(file.read_text())
            try:
                if os.getpgid(record['pid']) == record['pid']:
                    os.killpg(record['pid'], signal.SIGKILL)
            except ProcessLookupError:
                pass
