"""Use isolated native fixtures to verify development never adopts an installed app."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parents[1]
binary = os.environ.get('DEVBAR_TEST_BINARY', str(root / '.build/release/DevBar'))
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def until(check, message, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, KeyError, StopIteration):
            pass
        time.sleep(.15)
    raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='Development entry ', dir=root/'work') as folder:
    base = Path(folder)
    state = base/'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    identifiers = []
    apps = []
    def cli(*args, check=True):
        return subprocess.run([binary, *args], env=env, text=True, capture_output=True, check=check, timeout=45)

    def add(project, command='npm run dev'):
        ident = cli('--add-project', str(project), '--command', command).stdout.strip()
        identifiers.append(ident)
        return ident

    def session(project, target='dev'):
        key = hashlib.sha256((str(project)+'\n'+target).encode()).hexdigest()
        return json.loads((state/'development'/(key+'.json')).read_text())

    try:
        invalid = ['electron-vite build && electron-vite preview', 'electron-vite preview',
                   'next start', 'vite preview', 'vite build', 'node out/main/index.js',
                   'serve -s dist', 'electron .']
        for index, command in enumerate(invalid):
            project = base/('invalid-'+str(index)); project.mkdir()
            (project/'package.json').write_text(json.dumps({'scripts': {'dev': command}}))
            ident = add(project)
            result = cli('--start-project', ident, check=False)
            assert result.returncode != 0 and 'dev/watch' in result.stderr, result.stdout+result.stderr
        project = base/'build-alias'; project.mkdir()
        (project/'package.json').write_text(json.dumps({'scripts': {'dev':'npm run build', 'build':'node scripts/build-extension.js'}}))
        ident = add(project)
        result = cli('--start-project', ident, check=False)
        assert result.returncode != 0 and 'dev/watch' in result.stderr
        project = base/'profile'; project.mkdir()
        (project/'package.json').write_text(json.dumps({'scripts': {
            'dev': 'electron-vite build && electron-vite preview',
            'dev:hot': 'electron-vite dev --watch', 'start': 'electron .'},
            'devDependencies': {'electron':'1', 'electron-vite':'1'}}))
        profile = json.loads(cli('--profile-project', str(project)).stdout)
        desktop = next(t for t in profile['targets'] if t['kind']=='desktop')
        assert desktop['id']=='dev:hot', profile
        assert not any(t['id']=='dev' for t in profile['targets']), profile
        print('PASS: build/preview/artifact rejection and selection of the actual desktop development entry')

        swift_project = base/'declared-swift-development'; swift_project.mkdir()
        (swift_project/'Package.swift').write_text('let package=Package(targets:[.executableTarget(name:"Example")])')
        (swift_project/'package.json').write_text(json.dumps({'scripts': {'dev':'swift run Example'}}))
        swift_profile = json.loads(cli('--profile-project', str(swift_project)).stdout)
        assert swift_profile['targets'][0]['command'] == 'npm run dev', swift_profile
        assert swift_profile['targets'][0]['id'] == 'dev', swift_profile
        print('PASS: a declared development entry wins over inferred language-specific launch commands')

        # Native apps have no windows. Their independent bundle IDs exercise the
        # same Launch Services identity as a desktop app without visible windows.
        source = base/'Fixture.swift'
        source.write_text('''import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
 func applicationDidFinishLaunching(_ notification: Notification) {
  try! String(ProcessInfo.processInfo.processIdentifier).write(toFile: Bundle.main.bundlePath+".ready", atomically:true, encoding:.utf8)
 }
 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  try! "quit".write(toFile: Bundle.main.bundlePath+".quit", atomically:true, encoding:.utf8)
  return .terminateNow
 }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
''')
        helper = base/'fixture-binary'
        subprocess.run(['swiftc', str(source), '-o', str(helper)], check=True, capture_output=True, timeout=90)
        def launch_app(name, bundle_id):
            app = base/(name+'.app')
            executable = app/'Contents/MacOS/Fixture'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(helper.read_bytes()); executable.chmod(0o700)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier':bundle_id, 'CFBundleExecutable':'Fixture',
                'CFBundleName':name, 'CFBundlePackageType':'APPL', 'LSUIElement':True}))
            subprocess.run(['codesign','--force','--sign','-',str(app)], check=True, capture_output=True)
            subprocess.run(['open','-g','-n',str(app)], check=True)
            apps.append(app)
            until(lambda: Path(str(app)+'.ready').exists(), 'Fixture app did not start')
            return app

        installed = launch_app('Installed', 'dev.devbar.entry-fixture')
        unrelated = launch_app('Other', 'dev.devbar.other-fixture')
        project = base/'desktop-source'; project.mkdir()
        (project/'node_modules').mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
        server = project/'app.py'
        server.write_text(f'''import http.server, json, os
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({{"pid":os.getpid()}}).encode())
http.server.HTTPServer.allow_reuse_address=True
http.server.HTTPServer(("127.0.0.1",{port}),Handler).serve_forever()
''')
        (project/'package.json').write_text(json.dumps({'scripts': {'dev': shlex.quote(sys.executable)+' -u app.py'},
            'devDependencies': {'electron':'1'}, 'build': {'appId':'dev.devbar.entry-fixture'}}))
        ident = add(project)
        cli('--start-project', ident)
        def response():
            with http.open(f'http://127.0.0.1:{port}',timeout=.5) as reply:
                return json.load(reply)
        first = until(response, 'Development runtime did not start')
        assert not Path(str(installed)+'.quit').exists(), 'Development start terminated the installed application'
        assert not Path(str(unrelated)+'.quit').exists(), 'Unrelated application was terminated'
        cli('--restart-project', ident)
        until(lambda: response()['pid'] != first['pid'], 'Explicit restart did not replace the owned runtime')
        assert not Path(str(unrelated)+'.quit').exists()
        assert not Path(str(installed)+'.quit').exists(), 'Restart terminated the installed application'
        cli('--stop-project', ident)
        assert not Path(str(installed)+'.quit').exists(), 'Stop terminated the installed application'
        print('PASS: installed and unrelated apps survive development start/restart/stop')

        project = base/'failed-runtime'; project.mkdir()
        marker = base/'fail-on-start'; marker.write_text('fail')
        (project/'app.py').write_text(f'import pathlib,sys,time\nif pathlib.Path({str(marker)!r}).exists():sys.exit(4)\nwhile True:time.sleep(1)\n')
        (project/'package.json').write_text(json.dumps({'scripts': {'dev': shlex.quote(sys.executable)+' app.py'}}))
        ident = add(project)
        cli('--start-project', ident)
        before = until(lambda: (v if (v:=session(project))['phase']=='failed' else None), 'Failure not recorded')
        marker.unlink()
        cli('--start-project', ident)
        after = until(lambda: (v if (v:=session(project))['phase']=='watching' else None), 'Failed supervisor prevented direct retry')
        assert before['supervisor']['pid'] != after['supervisor']['pid']
        cli('--stop-project', ident)
        print('PASS: failed development supervisor can be retried without a source edit')
    finally:
        for ident in identifiers:
            cli('--stop-project', ident, check=False)
        for app in apps:
            ready = Path(str(app)+'.ready')
            if ready.exists() and not Path(str(app)+'.quit').exists():
                subprocess.run(['kill','-TERM',ready.read_text()], capture_output=True)
