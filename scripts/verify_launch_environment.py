"""Exercise the list's ProjectRunner path without opening any windows."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/debug/DevBar'))

with tempfile.TemporaryDirectory(prefix='devbar-launch-env-') as folder:
    base = Path(folder)
    environment = dict(os.environ, ELECTRON_RUN_AS_NODE='1',
                       DEVBAR_DATA_DIR=str(base / 'state'), DEVBAR_HEADLESS='1')

    def cli(*args, check=True):
        return subprocess.run([BINARY, *args], env=environment, capture_output=True,
                              text=True, timeout=45, check=check)

    for explicit in (False, True):
        project = base / ('explicit' if explicit else 'inherited')
        project.mkdir()
        (project / 'app.py').write_text(
            'import json,os,pathlib,time\n'
            'pathlib.Path("observed.json").write_text(json.dumps({\n'
            '  "electron":os.environ.get("ELECTRON_RUN_AS_NODE"),\n'
            '  "project":os.environ.get("DEVBAR_PROJECT_PATH")}))\n'
            'time.sleep(180)\n'
        )
        command = ('ELECTRON_RUN_AS_NODE=1 ' if explicit else '') + 'python3 app.py'
        identity = cli('--add-project', str(project), '--command', command).stdout.strip()
        try:
            cli('--start-project', identity)
            output = project / 'observed.json'
            deadline = time.monotonic() + 25
            while not output.exists() and time.monotonic() < deadline:
                time.sleep(.1)
            assert output.exists(), 'Project command never reached the environment probe'
            observed = json.loads(output.read_text())
            assert observed['electron'] == ('1' if explicit else None), observed
            assert observed['project'] == str(project), observed
        finally:
            cli('--stop-project', identity, check=False)

print('PASS: inherited Electron Node mode removed through ProjectRunner; explicit project opt-in and project environment preserved; no windows opened')
