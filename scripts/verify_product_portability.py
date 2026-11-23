"""Read-only discovery must follow selected tools and never run project scripts."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='Product portability ', dir=ROOT / 'work') as folder:
    base = Path(folder)
    workspace = base / 'workspace'
    workspace.mkdir()
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / 'state'), PATH='/usr/bin:/bin')

    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value) if isinstance(value, dict) else value)

    def cli(action, path, environment=env):
        result = subprocess.run([BINARY, action, str(path), '--json'], env=environment,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode in (0, 2), (result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout)

    tools = base / 'tools'
    write(tools / 'npm', '#!/bin/sh\nexit 99\n')
    (tools / 'npm').chmod(0o755)
    write(tools / 'xcodegen', '#!/bin/sh\ntouch MUST_NOT_RUN\n')
    (tools / 'xcodegen').chmod(0o755)
    env['PATH'] = str(tools) + ':/usr/bin:/bin'
    native = workspace / 'Native'
    write(native / 'project.yml', 'name: Native\ntargets:\n  Native:\n    type: application\n    platform: iOS\n')
    developer = base / 'Xcode Beta.app/Contents/Developer'
    write(developer / 'usr/bin/xcodebuild', '#!/bin/sh\ntouch MUST_NOT_RUN\n')
    (developer / 'usr/bin/xcodebuild').chmod(0o755)
    selected = dict(env, DEVELOPER_DIR=str(developer.parent.parent))
    native_capability = cli('doctor', native, selected)['capabilities'][0]
    native_issues = {issue['code'] for issue in native_capability['issues']}
    assert 'environmentMissing' not in native_issues and 'launchCommandRejected' in native_issues, native_capability
    invalid = dict(env, DEVELOPER_DIR=str(base / 'CommandLineTools'))
    native_capability = cli('doctor', native, invalid)['capabilities'][0]
    assert any(issue['code'] == 'environmentMissing' for issue in native_capability['issues']), native_capability
    assert cli('inventory', workspace, invalid)['state'] == 'unconfirmed'
    assert not (native / 'MUST_NOT_RUN').exists()

    android = workspace / 'Android'
    write(android / 'package.json', {'scripts': {'android': 'expo run:android'}, 'dependencies': {'expo': '1'}})
    write(android / 'node_modules/.bin/expo', '#!/bin/sh\nexit 99\n')
    (android / 'node_modules/.bin/expo').chmod(0o755)
    sdk = base / 'Android SDK'
    write(sdk / 'platform-tools/adb', '#!/bin/sh\nexit 99\n')
    (sdk / 'platform-tools/adb').chmod(0o755)
    sdk_env = dict(selected, ANDROID_HOME='', ANDROID_SDK_ROOT=str(sdk))
    assert cli('doctor', android, sdk_env)['capabilities'][0]['launch'] == 'available'
    path_env = dict(selected, ANDROID_HOME=str(base / 'missing'), ANDROID_SDK_ROOT='', PATH=str(sdk / 'platform-tools') + ':' + env['PATH'])
    assert cli('doctor', android, path_env)['capabilities'][0]['launch'] == 'available'

    node = workspace / 'Workspace'
    write(node / 'package.json', {'workspaces': ['apps/*']})
    child = node / 'apps/worker'
    write(child / 'package.json', {'scripts': {'dev:worker': 'nuxt dev'}})
    diagnosis = cli('doctor', node, selected)
    capability = next(t for t in diagnosis['capabilities'] if t['id'] == 'apps/worker:dev:worker')
    assert any(i['code'] == 'runtimeToolMissing' and 'nuxt' in i['message'] for i in capability['issues']), capability
    write(child / 'node_modules/.bin/nuxt', '#!/bin/sh\nexit 99\n')
    (child / 'node_modules/.bin/nuxt').chmod(0o755)
    assert next(t for t in cli('doctor', node, selected)['capabilities'] if t['id'] == capability['id'])['launch'] == 'available'

    unsupported = workspace / 'Unsupported'
    write(unsupported / 'package.json', {'packageManager': 'unknown@1', 'scripts': {'dev': 'touch MUST_NOT_RUN'}})
    assert any(i['code'] == 'packageManagerUnsupported' for i in cli('doctor', unsupported, selected)['issues'])
    outside = base / 'External'
    write(outside / 'package.json', {'scripts': {'dev': 'touch MUST_NOT_RUN'}})
    (workspace / 'Linked project').symlink_to(outside, target_is_directory=True)
    report = cli('inventory', workspace, selected)
    assert not any('Linked project' in p['path'] or p['path'] == str(outside) for p in report['projects'])
    assert report['skipped']['symbolicLink'] == 1
    assert not list(base.rglob('MUST_NOT_RUN'))
    print('PASS: selected/renamed Xcode, invalid toolchain blocks aggregate readiness, custom Android SDK/PATH, nested colon script dependencies, unsupported manager and top-level symlink isolation; no project script executed')
