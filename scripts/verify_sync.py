"""Exercise the actual macOS build/install/launch/status pipeline without opening windows."""
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))

with tempfile.TemporaryDirectory(prefix='Sync project with spaces ', dir=ROOT / 'work') as tmp:
    project = pathlib.Path(tmp)
    state = project / 'work/state'
    state.mkdir(parents=True)
    observed = project / 'work/observed.json'
    native = project / 'work/Fixture.m'
    native.write_text(r'''
#import <AppKit/AppKit.h>
#include <unistd.h>
int main(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *version = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"version" ofType:@"txt"] encoding:NSUTF8StringEncoding error:nil];
    if ([version hasPrefix:@"crash"]) return 42;
    NSDictionary *value = @{@"pid": @(getpid()), @"version": version ?: @"missing"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    [json writeToFile:OBSERVED atomically:YES];
    [app run];
  }
}
''')
    template = project / 'work/Fixture'
    subprocess.run(['clang', '-framework', 'AppKit', '-x', 'objective-c', str(native),
                    '-DOBSERVED=@' + json.dumps(str(observed)), '-o', str(template)], check=True, capture_output=True)
    source = project / 'source.txt'
    source.write_text('v1')
    artifact = project / 'dist/Fixture.app'
    installed = project / 'work/Installed Fixture.app'
    build = project / 'build.py'
    build.write_text('''import pathlib, plistlib, shutil, subprocess, time
root = pathlib.Path(__file__).parent
mode = (root/'work/mode').read_text() if (root/'work/mode').exists() else ''
if mode == 'fail': raise SystemExit(9)
if mode == 'wait': time.sleep(3)
if mode == 'timeout': time.sleep(30)
if mode == 'mutate': (root/'source.txt').write_text('changed during build')
app = root/'dist/Fixture.app'
if app.exists(): shutil.rmtree(app)
(app/'Contents/MacOS').mkdir(parents=True)
(app/'Contents/Resources').mkdir()
shutil.copy2(root/'work/Fixture', app/'Contents/MacOS/Fixture')
(app/'Contents/Resources/version.txt').write_text((root/'source.txt').read_text())
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.devbar.sync.fixture', 'CFBundleExecutable':'Fixture', 'CFBundlePackageType':'APPL', 'LSUIElement':True}))
subprocess.run(['codesign','--force','--sign','-',str(app)], check=True, capture_output=True)
with (root/'work/build-count').open('a') as f: f.write('build\\n')
''')
    config = project / '.devbar.json'
    target = {'buildCommand': 'python3 build.py', 'artifact': 'dist/Fixture.app',
              'installPath': str(installed), 'bundleIdentifier': 'local.devbar.sync.fixture',
              'sourcePaths': ['source.txt', 'build.py', '.devbar.json'], 'timeout': 30}
    config.write_text(json.dumps({'targets': {'desktop': target}}))
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    def cli(action, *extra, expected=0):
        result = subprocess.run([BINARY, action, str(project), '--json', *extra], env=env, text=True, capture_output=True, timeout=60)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout)
    def alive(pid):
        try: os.kill(pid, 0); return True
        except ProcessLookupError: return False
    def count(): return (project/'work/build-count').read_text().count('build')
    watcher = None
    try:
        assert cli('sync', '--plan')['state'] == 'planned'
        assert not artifact.exists() and not (state/'sync').exists(), 'Plan must be read-only'
        assert cli('status', expected=2)['state'] == 'unconfirmed'
        first = cli('sync')
        pid = first['receipt']['pid']
        assert json.loads(observed.read_text()) == {'pid': pid, 'version': 'v1'}
        assert cli('status')['state'] == 'current'
        assert cli('sync')['receipt']['pid'] == pid and count() == 1, 'Unchanged sync must not rebuild/restart'
        os.utime(source, None)
        assert cli('status')['state'] == 'current', 'Touch is not a content change'
        source.write_text('v2')
        assert cli('status', expected=2)['state'] == 'sourceChanged'
        second = cli('sync')
        pid2 = second['receipt']['pid']
        assert pid2 != pid and not alive(pid)
        assert json.loads(observed.read_text()) == {'pid': pid2, 'version': 'v2'}, 'Actual app must load new resource'
        # Exercise the actual automatic worker against a windowless native app.
        def watch():
            return subprocess.Popen([BINARY, '--test-auto-update-project', str(project)], env=env,
                                    stdout=(project/'work/auto.log').open('a'), stderr=subprocess.DEVNULL)
        def wait_version(version, timeout=30):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if observed.exists() and json.loads(observed.read_text())['version'] == version:
                    status = subprocess.run([BINARY, 'status', str(project), '--json'], env=env, text=True, capture_output=True, timeout=10)
                    if status.returncode == 0 and json.loads(status.stdout)['state'] == 'current': return
                time.sleep(.3)
            raise AssertionError((version, (project/'work/auto.log').read_text()))
        watcher = watch()
        for i in range(6):
            source.write_text('auto-draft-' + str(i)); time.sleep(.6)
        assert count() == 2, 'Continuous edits must not rebuild'
        source.write_text('auto-v1')
        wait_version('auto-v1')
        assert cli('status')['state'] == 'current' and count() == 3
        pid2 = json.loads(observed.read_text())['pid']
        (project/'work/mode').write_text('fail')
        source.write_text('auto-failed')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and 'failed:' not in (project/'work/auto.log').read_text(): time.sleep(.3)
        assert 'failed:' in (project/'work/auto.log').read_text(), 'Automatic failure must be visible'
        assert alive(pid2) and json.loads(observed.read_text())['version'] == 'auto-v1'
        watcher.terminate(); watcher.wait(timeout=5)
        (project/'work/mode').unlink()
        before_logs = len(list((state/'sync').glob('*.log')))
        watcher = watch(); time.sleep(7)
        assert len(list((state/'sync').glob('*.log'))) == before_logs, 'Restart must not retry failed source'
        # Manual retry remains available, without recording a new baseline.
        assert cli('sync')['state'] == 'current'
        source.write_text('auto-v2'); wait_version('auto-v2')
        watcher.terminate(); watcher.wait(timeout=5); watcher = None
        pid2 = json.loads(observed.read_text())['pid']
        print('PASS: real automatic native update after quiet period, continuous edits, actual new payload/PID, sync/status, failed build preserves app, failure survives monitor restart, manual retry and next change recovery')
        receipt = next((state/'sync').glob('*.json'))
        assert receipt.stat().st_mode & 0o777 == 0o600
        (installed/'Contents/Resources/version.txt').write_text('tampered')
        assert cli('status', expected=2)['state'] == 'artifactChanged'
        pid2 = cli('sync')['receipt']['pid']
        source.write_text('v3')
        (project/'work/mode').write_text('fail')
        failed = cli('sync', expected=1)
        assert failed['state'] == 'failed' and alive(pid2), 'Failed build must preserve running app'
        assert pathlib.Path(failed['log']).stat().st_mode & 0o777 == 0o600
        (project/'work/mode').write_text('mutate')
        assert cli('sync', expected=1)['state'] == 'failed' and alive(pid2), 'Reject source changes during build'
        source.write_text('v4')
        (project/'work/mode').write_text('wait')
        pending = subprocess.Popen([BINARY, 'sync', str(project), '--json'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(.8)
            assert cli('sync', expected=2)['state'] == 'busy'
            out, err = pending.communicate(timeout=60)
            assert pending.returncode == 0, (out, err)
            pid2 = json.loads(out)['receipt']['pid']
        finally:
            if pending.poll() is None: pending.terminate(); pending.wait(timeout=5)
        (project/'work/mode').unlink()
        source.write_text('crash')
        failure = cli('sync', expected=1)
        assert failure['state'] == 'failed'
        assert (installed/'Contents/Resources/version.txt').read_text() == 'v4', 'Restore previous bundle on launch failure'
        time.sleep(.5)
        restored = json.loads(observed.read_text())
        assert restored['version'] == 'v4' and alive(restored['pid']), 'Restore previous running application'
        assert cli('status', expected=2)['state'] != 'current', 'Rollback must not claim latest'
        source.write_text('v5')
        final = cli('sync')
        os.kill(final['receipt']['pid'], signal.SIGTERM)
        time.sleep(.5)
        assert cli('status', expected=2)['state'] == 'stopped'
        target['bundleIdentifier'] = 'wrong.identifier'
        config.write_text(json.dumps({'targets': {'desktop': target}}))
        assert cli('sync', expected=1)['state'] == 'failed', 'Identity mismatch must not install'
        assert (installed/'Contents/Resources/version.txt').read_text() == 'v5'
        target['bundleIdentifier'] = 'local.devbar.sync.fixture'
        target['timeout'] = 5
        config.write_text(json.dumps({'targets': {'desktop': target}}))
        source.write_text('v6')
        (project/'work/mode').write_text('timeout')
        timed = cli('sync', expected=1)
        assert timed['state'] == 'failed' and '超时' in timed['reason']
        assert (installed/'Contents/Resources/version.txt').read_text() == 'v5', 'Timeout must not replace installed content'
        (project/'work/mode').unlink()
        target['installPath'] = str(project.parent) + '.app'
        target['artifact'] = str(project.parent) + '.app/Contents/Child.app'
        config.write_text(json.dumps({'targets': {'desktop': target}}))
        assert cli('sync', '--plan', expected=1)['state'] == 'setupRequired', 'Reject artifact outside project before executing'
        target['installPath'] = str(installed)
        target['artifact'] = 'dist/Fixture.app'
        config.write_text(json.dumps({'targets': {'desktop': target}}))
        external = project/'work/outside-link'
        external.symlink_to('/etc/hosts')
        target['sourcePaths'].append('work/outside-link')
        config.write_text(json.dumps({'targets': {'desktop': target}}))
        assert cli('sync', expected=1)['state'] == 'setupRequired', 'External source scope must not be silently hashed'
        assert cli('sync', '--target', 'missing', expected=1)['state'] == 'setupRequired'
        print('PASS: real background native App v1→v2, idempotence, content/touch checks, process identity, build failure/timeout, source race, concurrency lock, crash rollback, stale PID, wrong identity, external path rejection, JSON/private logs; no browser or foreground window')
    finally:
        if watcher is not None and watcher.poll() is None:
            watcher.terminate(); watcher.wait(timeout=5)
        # Only stop the fixture executable in this isolated installation.
        result = subprocess.run(['pgrep', '-f', str(installed/'Contents/MacOS/Fixture')], capture_output=True, text=True)
        for value in result.stdout.split():
            try: os.kill(int(value), signal.SIGTERM)
            except ProcessLookupError: pass
