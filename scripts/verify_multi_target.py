"""Exercise independent development sessions without opening a browser."""
from pathlib import Path
import json, os, socket, subprocess, tempfile, time, urllib.request

root = Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='DevBar targets ', dir=root / 'work') as folder:
    base = Path(folder)
    project = base / 'project'
    project.mkdir()
    ports = []
    for _ in range(2):
        s = socket.socket(); s.bind(('127.0.0.1', 0)); ports.append(s.getsockname()[1]); s.close()
    (project / 'package.json').write_text(json.dumps({'scripts': {
        'dev': f'python3 -m http.server {ports[0]} --bind 127.0.0.1',
        'dev:backend': f'python3 -m http.server {ports[1]} --bind 127.0.0.1',
    }}))
    (project / 'index.html').write_text('multi-target fixture')
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / 'state'))
    def cli(*args, check=True):
        return subprocess.run([binary, *args], env=env, capture_output=True, text=True, check=check, timeout=45)
    def ready(port):
        try:
            return urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=.5).status == 200
        except Exception:
            return False
    def until(predicate):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.2)
        raise AssertionError('target state timed out')
    ident = cli('--add-project', str(project)).stdout.strip()
    try:
        cli('--start-project', ident, '--target', 'dev'); until(lambda: ready(ports[0]))
        cli('--start-project', ident, '--target', 'dev:backend'); until(lambda: ready(ports[1]))
        assert ready(ports[0]) and ready(ports[1])
        assert cli('--start-project', ident, '--target', 'dev', check=False).returncode != 0
        assert cli('--stop-project', ident, check=False).returncode != 0
        cli('--stop-project', ident, '--target', 'dev'); until(lambda: not ready(ports[0]))
        assert ready(ports[1]), 'stopping first target stopped the second'
        cli('--start-project', ident, '--target', 'dev'); until(lambda: ready(ports[0]))
        cli('--stop-project', ident, '--target', 'dev:backend'); until(lambda: not ready(ports[1]))
        assert ready(ports[0]), 'stopping second target stopped the first'
        cli('--stop-project', ident, '--target', 'dev'); until(lambda: not ready(ports[0]))
        print('PASS: simultaneous targets, duplicate protection, ambiguous stop, independent stop and restart')
    finally:
        for target in ('dev', 'dev:backend'):
            cli('--stop-project', ident, '--target', target, check=False)
