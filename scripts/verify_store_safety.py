"""Corrupt or hostile local project records must fail without data loss or crashes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('DEVBAR_TEST_BINARY', ROOT / '.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='DevBar store safety ') as folder:
    base = Path(folder)
    project = base / 'Project'; project.mkdir()
    state = base / 'state'; state.mkdir()
    config = state / 'projects.json'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    row = dict(id='valid-project', name='Project', path=str(project), command='')
    invalid = [
        b'{broken',
        json.dumps([row, row]).encode(),
        json.dumps([row, dict(row, id='second')]).encode(),
        json.dumps([dict(row, id='../escape')]).encode(),
        json.dumps([dict(row, path='relative/path')]).encode(),
        json.dumps([dict(row, targetID='first\nsecond')]).encode(),
        json.dumps([dict(row, command='x\0y')]).encode(),
    ]
    for content in invalid:
        config.write_bytes(content)
        for args in [('--list-projects',), ('--add-project', str(project)), ('--menu-json',)]:
            result = subprocess.run([str(BINARY), *args], env=env, text=True,
                                    capture_output=True, timeout=30)
            assert result.returncode == 1, (args, result.returncode, result.stderr)
            assert config.read_bytes() == content
    missing = dict(row, path=str(base / 'Moved away'))
    config.write_text(json.dumps([missing]))
    result = subprocess.run([str(BINARY), '--list-projects'], env=env, text=True,
                            capture_output=True, check=True, timeout=10)
    assert json.loads(result.stdout) == [missing], 'Missing folders must remain recoverable'
    config.unlink()
    os.mkfifo(config)
    result = subprocess.run([str(BINARY), '--list-projects'], env=env, text=True,
                            capture_output=True, timeout=5)
    assert result.returncode == 1 and config.is_fifo(), result.stderr
    config.unlink()
    bundle = base / 'Applications/QuiX Dev.app'
    contents = bundle / 'Contents'
    contents.mkdir(parents=True)
    (contents / 'Info.plist').write_text('<plist><dict/></plist>')
    (contents / 'package.json').write_text('{"scripts":{"dev":"node server.js"}}')
    alias = base / 'Bundle alias'
    alias.symlink_to(contents, target_is_directory=True)
    bundle_rows = [dict(row, id=f'bundle-{i}', name='Contents', path=str(path))
                   for i, path in enumerate((bundle, contents, alias))]
    config.write_text(json.dumps([row, *bundle_rows]))
    original = config.read_bytes()
    result = subprocess.run([str(BINARY), '--list-projects'], env=env, text=True,
                            capture_output=True, check=True, timeout=10)
    assert json.loads(result.stdout) == [row], result.stdout
    assert config.read_bytes() == original, 'Reading must preserve legacy configuration'
    for path in (bundle, contents, alias):
        result = subprocess.run([str(BINARY), '--add-project', str(path)], env=env,
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 1, (path, result.stdout, result.stderr)
        assert config.read_bytes() == original
        result = subprocess.run([str(BINARY), '--profile-project', str(path)], env=env,
                                text=True, capture_output=True, check=True, timeout=10)
        assert json.loads(result.stdout)['targets'] == [], result.stdout
print('PASS: duplicate/traversal/invalid/special records fail safely; original data and missing folders retained')
print('PASS: legacy application bundles hidden; bundle roots, Contents and symlink aliases rejected')
