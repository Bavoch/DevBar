"""Exercise persisted start/stop recency using isolated projects and processes."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
binary = root / '.build/release/DevBar'
with tempfile.TemporaryDirectory(prefix='Recency ', dir=root / 'work') as folder:
    base = Path(folder)
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / 'state'))
    ids = []
    def cli(*args):
        return subprocess.run([binary, *args], env=env, text=True, capture_output=True, check=True, timeout=50).stdout.strip()
    def listening(port):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1): return True
        except OSError: return False
    def wait(predicate):
        for _ in range(200):
            if predicate(): return
            time.sleep(.1)
        raise AssertionError('timed out')
    def project_rows():
        return [row['title'] for row in json.loads(cli('--menu-json')) if row.get('value') in paths]
    try:
        paths, ports = [], []
        for name in ('Alpha', 'Beta'):
            project = base / name; project.mkdir(); paths.append(str(project))
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); ports.append(sock.getsockname()[1])
            (project / 'package.json').write_text('{}')
            command = f'{sys.executable} -m http.server {ports[-1]} --bind 127.0.0.1'
            ids.append(cli('--add-project', str(project), '--name', name, '--command', command))
        assert project_rows() == ['Alpha', 'Beta']
        cli('--start-project', ids[0]); wait(lambda: listening(ports[0]))
        cli('--start-project', ids[1]); wait(lambda: listening(ports[1]))
        assert project_rows() == ['Beta', 'Alpha']
        cli('--stop-project', ids[1]); wait(lambda: not listening(ports[1]))
        cli('--stop-project', ids[0]); wait(lambda: not listening(ports[0]))
        assert project_rows() == ['Alpha', 'Beta']
        activity = json.loads((base / 'state' / 'activity.json').read_text())
        assert activity[paths[0]] > activity[paths[1]]
        print('PASS: running and stopped lists persist most recent explicit operation first')
    finally:
        for ident in ids:
            subprocess.run([binary, '--stop-project', ident], env=env, text=True, capture_output=True, timeout=50)
