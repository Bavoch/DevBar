"""Use the actual panel action on an unregistered terminal-launched project."""
from pathlib import Path
import json
import os
import plistlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def ready(number):
    try:
        with socket.create_connection(('127.0.0.1', number), timeout=.1): return True
    except OSError: return False

def wait(check):
    end = time.monotonic() + 30
    while time.monotonic() < end:
        if check(): return
        time.sleep(.1)
    raise AssertionError('runtime did not reach expected state')

with tempfile.TemporaryDirectory(prefix='Unified control ', dir=ROOT / 'work') as folder:
    base = Path(folder)
    project = base / 'Project with spaces'; project.mkdir()
    other = base / 'Unrelated'; other.mkdir()
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    main_port, tool_port, other_port, helper_port = port(), port(), port(), port()
    source = f'import http.server\nhttp.server.HTTPServer.allow_reuse_address=True\nhttp.server.HTTPServer(("127.0.0.1",{main_port}),http.server.SimpleHTTPRequestHandler).serve_forever()\n'
    (project / 'server.py').write_text(source)
    (project / 'agentation-mcp.py').write_text(source.replace(str(main_port), str(tool_port)))
    (project / 'package.json').write_text(json.dumps({'scripts': {'dev': shlex.quote(sys.executable) + ' server.py'}}))
    (other / 'package.json').write_text('{}')
    command = shlex.join([sys.executable, 'server.py']) + ' & child=$!; wait $child; sleep 120'
    terminal = subprocess.Popen(['/bin/zsh', '-c', command], cwd=project, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tool = subprocess.Popen([sys.executable, str(project / 'agentation-mcp.py')], cwd=project,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    unrelated = subprocess.Popen([sys.executable, '-m', 'http.server', str(other_port), '--bind', '127.0.0.1'], cwd=other,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    helper = subprocess.Popen([sys.executable, '-c',
        f'import http.server; http.server.HTTPServer(("127.0.0.1",{helper_port}),http.server.SimpleHTTPRequestHandler).serve_forever()'],
        cwd=project, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    identifier = None
    restarted_terminal = None
    mixed_runtime = None
    def cli(*args):
        return subprocess.run([BINARY, *args], env=env, text=True, capture_output=True, check=True, timeout=60)
    try:
        wait(lambda: ready(main_port) and ready(tool_port) and ready(other_port) and ready(helper_port))
        assert not (state / 'projects.json').exists()
        menus = json.loads(cli('--menu-json').stdout)
        row = next(item for item in menus if item.get('value') == str(project))
        assert any(item['title'] == '停止' and item.get('action') == 'stopProject:' for item in row['items'])
        assert not any('其他应用' in item['title'] or '外部' in item['title'] for item in row['items'])
        result = cli('--self-test-interaction-latency', '--stop-fixture', str(project))
        print(result.stdout, end='')
        wait(lambda: not ready(main_port))
        assert terminal.poll() is None, 'Shared terminal launcher was killed'
        assert ready(tool_port) and tool.poll() is None, 'AI/MCP tool was killed'
        assert ready(other_port) and ready(helper_port), 'Unrelated project or same-folder helper was stopped'
        config = next(item for item in json.loads(cli('--list-projects').stdout) if item['path'] == str(project))
        identifier = config['id']
        stopped = next(item for item in json.loads(cli('--menu-json').stdout) if item.get('value') == str(project))
        assert any(item.get('action') == 'startProject:' for item in stopped['items'])
        assert not any(item.get('action') == 'stopProject:' for item in stopped['items']), 'An unrelated listening helper kept the project running'
        cli('--start-project', identifier)
        wait(lambda: ready(main_port))
        cli('--stop-project', identifier)
        wait(lambda: not ready(main_port))
        assert terminal.poll() is None and ready(tool_port) and ready(other_port)
        (project/'external.py').write_text(source)
        cli('--start-project', identifier)
        wait(lambda: ready(main_port))
        (project/'server.py').write_text('syntax error !')
        wait(lambda: not ready(main_port) and any(json.loads(file.read_text()).get('phase') == 'failed'
             for file in (state/'development').glob('*.json')))
        mixed_runtime = subprocess.Popen([sys.executable, 'external.py'], cwd=project,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait(lambda: ready(main_port))
        mixed_row = next(item for item in json.loads(cli('--menu-json').stdout) if item.get('value') == str(project))
        assert any(item['title'] == '停止' and item.get('action') == 'stopProject:' for item in mixed_row['items']), 'A failed supervisor hid the live project control'
        mixed_stop = cli('--self-test-interaction-latency', '--stop-fixture', str(project))
        print(mixed_stop.stdout, end='')
        wait(lambda: not ready(main_port))
        mixed_runtime.wait(timeout=5)
        assert ready(tool_port) and ready(helper_port) and ready(other_port)
        (project/'server.py').write_text(source)
        (project/'external.py').unlink()
        print('PASS: failed supervision does not hide a healthy runtime; one project Stop handles all confirmed instances')

        restarted_terminal = subprocess.Popen(['/bin/zsh', '-c', command], cwd=project, start_new_session=True,
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait(lambda: ready(main_port))
        (project / 'package.json').write_text(json.dumps({'scripts': {'dev': 'vite preview'}}))
        invalid = subprocess.run([BINARY, '--restart-project', identifier], env=env, text=True, capture_output=True, timeout=30)
        assert invalid.returncode != 0 and ready(main_port), 'Invalid restart stopped the working instance'
        (project / 'package.json').write_text(json.dumps({'scripts': {
            'dev': shlex.quote(sys.executable) + ' server.py', 'dev:backend': shlex.quote(sys.executable) + ' server.py'}}))
        records = json.loads((state / 'projects.json').read_text())
        for entry in records:
            if entry['id'] == identifier:
                entry['command'] = ''; entry.pop('targetID', None)
        (state / 'projects.json').write_text(json.dumps(records))
        ambiguous = subprocess.run([BINARY, '--restart-project', identifier], env=env, text=True, capture_output=True, timeout=30)
        assert ambiguous.returncode != 0 and '多个运行方式' in ambiguous.stderr and ready(main_port)
        row = next(item for item in json.loads(cli('--menu-json').stdout) if item.get('value') == str(project))
        more = next(item['items'] for item in row['items'] if item['title'] == '更多')
        choices = next(item['items'] for item in more if item['title'] == '运行方式')
        assert all(item.get('action') == 'selectTarget:' and '已停止' not in item['title'] for item in choices)
        cli('--select-target', identifier, '--target', 'dev')
        (project / 'package.json').write_text(json.dumps({'scripts': {'dev': shlex.quote(sys.executable) + ' server.py'}}))
        cli('stop', str(project), '--target', 'dev', '--json')
        wait(lambda: not ready(main_port))
        assert restarted_terminal.poll() is None and ready(tool_port) and ready(other_port)
        print('PASS: unified panel/CLI Stop/Run, persistence, prevalidated restart, terminal/AI/unrelated-process protection')

        native_project = base / 'Native project'; native_project.mkdir()
        native = native_project / 'build/Fixture.app'
        (native / 'Contents/MacOS').mkdir(parents=True)
        pid_file = native_project / 'pid.txt'
        allow_file = native_project / 'allow-quit'
        objc = native_project / 'Fixture.m'
        objc.write_text(r'''#import <AppKit/AppKit.h>
#include <unistd.h>
@interface Delegate : NSObject <NSApplicationDelegate>
@end
@implementation Delegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
 return [[NSFileManager defaultManager] fileExistsAtPath:ALLOW_FILE] ? NSTerminateNow : NSTerminateCancel;
}
@end
int main(void) { @autoreleasepool {
 NSApplication *application=NSApplication.sharedApplication;
 [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
 Delegate *delegate=[Delegate new]; application.delegate=delegate;
 [[NSString stringWithFormat:@"%d",getpid()] writeToFile:PID_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
 [application run];
} return 0; }
''')
        executable = native / 'Contents/MacOS/Fixture'
        subprocess.run(['clang', '-framework', 'AppKit', str(objc),
                        '-DPID_FILE=@'+json.dumps(str(pid_file)), '-DALLOW_FILE=@'+json.dumps(str(allow_file)),
                        '-o', str(executable)], check=True, capture_output=True)
        (native / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.devbar.unified.'+str(os.getpid()),
            'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL', 'LSUIElement': True}))
        subprocess.run(['codesign', '--force', '--sign', '-', str(native)], check=True, capture_output=True)
        native_id = cli('--add-project', str(native_project), '--command', '').stdout.strip()
        subprocess.run(['open', '-g', '-j', '-n', str(native)], check=True, capture_output=True)
        wait(pid_file.exists)
        native_pid = int(pid_file.read_text())
        try:
            refused = subprocess.run([BINARY, '--stop-project', native_id], env=env, text=True, capture_output=True, timeout=30)
            assert refused.returncode != 0, 'App refusing Quit must not be force-killed or reported stopped'
            os.kill(native_pid, 0)
            allow_file.touch()
            cli('--stop-project', native_id)
            def gone():
                status=subprocess.run(['ps', '-p', str(native_pid), '-o', 'stat='], text=True, capture_output=True).stdout.strip()
                return not status or 'Z' in status
            wait(gone)
            print('PASS: discovered native app receives graceful Quit; unsaved-work refusal stays running; retry exits normally')
            # Exercise the same refusal through DevBar's own build/launch chain.
            (native_project / 'Info.plist').write_bytes((native/'Contents/Info.plist').read_bytes())
            (native_project / 'scripts').mkdir()
            (native_project / 'scripts/build.sh').write_text('sleep 4\n')
            allow_file.unlink()
            pid_file.unlink()
            cli('--start-project', native_id)
            wait(lambda: any(json.loads(p.read_text()).get('phase') == 'starting'
                             for p in (state/'development').glob('*.json')))
            assert not pid_file.exists(), 'Build stage was mistaken for a ready native app'
            wait(pid_file.exists)
            native_pid = int(pid_file.read_text())
            wait(lambda: any(json.loads(p.read_text()).get('phase') == 'watching'
                             for p in (state/'development').glob('*.json')))
            refused = subprocess.run([BINARY, '--stop-project', native_id], env=env, text=True, capture_output=True, timeout=30)
            assert refused.returncode != 0, 'Managed app refusing Quit was force-killed'
            os.kill(native_pid, 0)
            allow_file.touch()
            cli('--stop-project', native_id)
            wait(gone)
            print('PASS: managed native build stays starting; Quit refusal preserves the app and its launcher; retry stops normally')
        finally:
            current=subprocess.run(['ps','-p',str(native_pid),'-o','comm='],text=True,capture_output=True).stdout.strip()
            if current == str(executable): os.kill(native_pid, signal.SIGTERM)
    finally:
        if identifier:
            subprocess.run([BINARY, '--stop-project', identifier], env=env, capture_output=True, timeout=45)
        for child in (tool, unrelated, helper, mixed_runtime):
            if child is not None:
                if child.poll() is None: child.terminate()
                child.wait(timeout=5)
        for shell in (terminal, restarted_terminal):
            if shell is not None:
                if shell.poll() is None: os.killpg(shell.pid, signal.SIGTERM)
                shell.wait(timeout=5)
