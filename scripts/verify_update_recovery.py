"""Invalid configuration must leave actual menu recovery and opt-out accessible."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='DevBar update recovery ') as folder:
    base = Path(folder)
    project = base / 'Project'; project.mkdir()
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    def cli(*args):
        return subprocess.check_output([BINARY, *args], env=env, text=True, timeout=45)
    cli('--add-project', str(project), '--name', 'Recovery fixture', '--command', 'exit 99')
    saved = state / 'projects.json'
    records = json.loads(saved.read_text())
    records[0]['autoUpdateTarget'] = 'desktop'
    saved.write_text(json.dumps(records))
    config = project / '.devbar.json'
    for content in (None, '{broken', json.dumps({'targets': {'desktop': {'strategy': 'process', 'startCommand': 'exit 99'}}})):
        if content is None:
            config.unlink(missing_ok=True)
        else:
            config.write_text(content)
        before = config.read_bytes() if config.exists() else None
        menu = cli('--menu-json')
        assert '设置应用更新…' in menu, menu
        assert '关闭自动更新' in menu, menu
        assert (config.read_bytes() if config.exists() else None) == before
    assert json.loads(saved.read_text())[0]['autoUpdateTarget'] == 'desktop'
print('PASS: missing/malformed/changed targets retain menu setup and opt-out without changing project configuration')
