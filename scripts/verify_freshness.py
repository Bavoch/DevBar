"""Observe an external process without starting any project commands."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Runtime version ', dir=root / 'work') as tmp:
    base = pathlib.Path(tmp)
    project = base / 'External project'
    project.mkdir()
    (project / 'package.json').write_text(json.dumps({'scripts': {'dev': 'touch MUST_NOT_RUN'}}))
    source = project / 'run.py'
    source.write_text('import time; time.sleep(180)\n')
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state))
    process = None
    def cli(flag):
        result = subprocess.run([binary, flag, str(project)], env=env, capture_output=True, text=True, check=True, timeout=45)
        return json.loads(result.stdout)
    def start():
        result = subprocess.Popen([sys.executable, str(source)], cwd=project, start_new_session=True)
        time.sleep(.2)
        return result
    try:
        process = start()
        assert cli('--freshness-project')['state'] == 'unknown'
        assert not (state / 'freshness').exists(), 'Read-only diagnostics must not create history'
        assert cli('--record-runtime')['state'] == 'unknown'
        history = list((state / 'freshness').glob('*.json'))
        assert len(history) == 1 and history[0].stat().st_mode & 0o777 == 0o600
        os.utime(source, None)
        assert cli('--freshness-project')['state'] == 'unknown', 'Touch alone must not warn'
        source.write_text('import time; time.sleep(181)\n')
        assert cli('--freshness-project')['state'] == 'sourceChanged'
        assert cli('--record-runtime')['state'] == 'sourceChanged', 'Refresh must preserve the original baseline'
        assert cli('--freshness-project')['state'] == 'sourceChanged'
        process.terminate(); process.wait(timeout=5)
        process = start()
        assert cli('--record-runtime')['state'] == 'unknown', 'A new runtime needs a new baseline'
        assert cli('--freshness-project')['state'] == 'unknown'
        assert not (project / 'MUST_NOT_RUN').exists()
        print('PASS: live external process, read-only scan, private baseline, touch-only edit, persistent source warning, restart reset; no project command executed')
    finally:
        if process and process.poll() is None:
            process.terminate(); process.wait(timeout=5)
