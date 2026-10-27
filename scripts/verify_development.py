"""Development start must watch source, preserve dev commands and never install an app."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def until(check, message, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, StopIteration):
            pass
        time.sleep(.2)
    raise AssertionError(message)

with tempfile.TemporaryDirectory(prefix='Development ', dir=root/'work') as folder:
    base = Path(folder)
    state = base/'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state), DEVBAR_HEADLESS='1')
    identifiers = []

    def cli(*args, check=True):
        return subprocess.run([binary, *args], env=env, text=True, capture_output=True, check=check, timeout=45)

    def add(project):
        ident = cli('--add-project', str(project)).stdout.strip()
        identifiers.append(ident)
        cli('--start-project', ident)
        return ident

    def live_state(project):
        ident = next(p['id'] for p in json.loads(cli('--list-projects').stdout) if p['path'] == str(project))
        records = [json.loads(p.read_text()) for p in state.glob(f'{ident}.target-*.run.json')]
        target = records[0]['targetID']
        key = hashlib.sha256((str(project) + '\n' + target).encode()).hexdigest()
        return json.loads((state/'development'/(key+'.json')).read_text())

    try:
        project = base/'Desktop with spaces'
        project.mkdir()
        (project/'node_modules').mkdir()
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        (project/'package.json').write_text(json.dumps({'scripts': {'dev': f'{shlex.quote(sys.executable)} -u app.py'}, 'devDependencies': {'electron':'1'}}))
        (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1, 'targets': {'dev': {'strategy':'macBundle', 'buildCommand':'touch INSTALL_MUST_NOT_RUN', 'artifact':'dist/Fixture.app', 'installPath':str(base/'Installed.app')}}}))
        source = project/'app.py'

        def server(version):
            return f'''import http.server, json, os
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  body=json.dumps({{'version': {version!r}, 'pid': os.getpid()}}).encode()
  self.send_response(200); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer.allow_reuse_address=True
http.server.HTTPServer(('127.0.0.1',{port}),Handler).serve_forever()
'''

        def response():
            with http.open(f'http://127.0.0.1:{port}', timeout=.5) as output:
                return json.load(output)

        source.write_text(server('v1'))
        ident = add(project)
        first = until(response, 'Development server did not start')
        assert first['version'] == 'v1'
        assert not (project/'INSTALL_MUST_NOT_RUN').exists()
        menus = cli('--menu-json').stdout
        assert not any(text in menus for text in ['设置应用更新', '更新其他目标', '自动更新', '更新日志'])
        source.write_text(server('v2'))
        second = until(lambda: (r if (r := response())['version'] == 'v2' else None), 'Source edit did not restart runtime')
        assert first['pid'] != second['pid']
        (project/'dist').mkdir()
        (project/'dist/generated.txt').write_text('output')
        time.sleep(1.5)
        assert response()['pid'] == second['pid'], 'Generated output caused restart loop'
        source.write_text('syntax error !')
        until(lambda: live_state(project)['phase'] == 'failed', 'Compile failure not visible')
        source.write_text(server('v3'))
        until(lambda: response()['version'] == 'v3', 'Failed command did not recover after edit')
        cli('--stop-project', ident)
        until(lambda: not subprocess.run(['kill', '-0', str(second['pid'])], capture_output=True).returncode == 0, 'Old runtime remained')
        cli('--start-project', ident)
        until(lambda: response()['version'] == 'v3', 'Cannot restart stopped development session')
        cli('--stop-project', ident)
        print('PASS: desktop dev command ignores macBundle sync; source restart, generated-output exclusion, failure/recovery, stop/restart, no update menus')

        swift = base/'Swift watcher'
        (swift/'Sources/Fixture').mkdir(parents=True)
        (swift/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name:"Fixture",targets:[.executableTarget(name:"Fixture")])\n')
        main = swift/'Sources/Fixture/main.swift'
        def swift_source(version):
            return f'import Foundation\nprint("SWIFT_{version}"); fflush(stdout)\nwhile true {{ Thread.sleep(forTimeInterval: 1) }}\n'
        main.write_text(swift_source('v1'))
        sid = add(swift)
        log = state/(sid+'.log')
        until(lambda: 'SWIFT_v1' in log.read_text(), 'Swift initial build failed', 90)
        main.write_text(swift_source('v2'))
        until(lambda: 'SWIFT_v2' in log.read_text(), 'Swift edit did not rebuild/restart', 90)
        cli('--stop-project', sid)
        print('PASS: actual Swift build and source-triggered recompile/restart')

        preview = base/'Preview is not development'
        preview.mkdir()
        (preview/'package.json').write_text(json.dumps({'scripts': {'dev': 'vite preview'}}))
        preview_id = cli('--add-project', str(preview)).stdout.strip()
        identifiers.append(preview_id)
        rejected = cli('--start-project', preview_id, check=False)
        assert rejected.returncode != 0 and 'dev/watch' in rejected.stderr, rejected.stderr
        print('PASS: production preview is rejected as a development command')

        # Optional browser checks share the normal DevBar start path. The CLI is
        # explicitly headless and uses an isolated session and configuration.
        pwcli = os.environ.get('DEVBAR_TEST_PLAYWRIGHT_CLI')
        if pwcli:
            session = 'devbar-development-'+str(os.getpid())
            config = base/'browser.json'
            config.write_text(json.dumps({'browser': {'browserName':'chromium', 'launchOptions': {'headless': True, 'channel': 'chrome'}}}))
            browser_env = dict(env, PLAYWRIGHT_CLI_SESSION=session)
            def browser(*args):
                result = subprocess.run([pwcli, *args], env=browser_env, cwd=root, text=True, capture_output=True, timeout=45)
                assert result.returncode == 0, result.stdout + result.stderr
                return result.stdout
            try:
                static = base/'Static'
                static.mkdir()
                document = static/'index.html'
                document.write_text('<!doctype html><h1>STATIC_v1</h1>')
                static_id = add(static)
                static_log = state/(static_id+'.log')
                import re
                url = until(lambda: re.search(r'DevBar static development: (http://[^\s]+)', static_log.read_text()), 'Static live server not started').group(1)
                browser('open', url, '--config', str(config))
                assert 'STATIC_v1' in browser('snapshot')
                document.write_text('<!doctype html><h1>STATIC_v2</h1>')
                until(lambda: 'STATIC_v2' in browser('snapshot'), 'Static document did not reload automatically')
                cli('--stop-project', static_id)
                print('PASS: static HTML automatically reloads in a headless browser without manual refresh')

                candidates = list(root.parent.glob('*/node_modules/vite/bin/vite.js'))
                assert candidates, 'Need an existing local Vite installation for HMR verification'
                web = base/'Vite'
                web.mkdir()
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1',0)); vite_port = sock.getsockname()[1]
                (web/'package.json').write_text(json.dumps({'scripts': {'dev': f'node {shlex.quote(str(candidates[0]))} --port {vite_port} --strictPort --host 127.0.0.1'}}))
                (web/'index.html').write_text('<!doctype html><h1>VITE</h1><script type="module" src="/main.js"></script>')
                js = web/'main.js'
                js.write_text('document.querySelector("h1").textContent="VITE_v1"; if(import.meta.hot) import.meta.hot.accept();')
                wid = add(web)
                until(lambda: http.open(f'http://127.0.0.1:{vite_port}',timeout=.5).status==200, 'Vite did not start')
                browser('goto',f'http://127.0.0.1:{vite_port}')
                assert 'VITE_v1' in browser('snapshot')
                browser('eval', '() => { window.devbarHMRSession = true; return true }')
                before_pid = subprocess.check_output(['lsof','-nP',f'-iTCP:{vite_port}','-sTCP:LISTEN','-t'],text=True).strip()
                js.write_text('document.querySelector("h1").textContent="VITE_v2"; if(import.meta.hot) import.meta.hot.accept();')
                until(lambda: 'VITE_v2' in browser('snapshot'), 'Vite HMR did not apply visible source edit')
                assert 'true' in browser('eval', '() => window.devbarHMRSession === true'), 'Vite update unnecessarily reloaded page'
                assert subprocess.check_output(['lsof','-nP',f'-iTCP:{vite_port}','-sTCP:LISTEN','-t'],text=True).strip() == before_pid, 'Vite source edit restarted dev server'
                cli('--stop-project', wid)
                print('PASS: real Vite HMR visibly applies source edit in headless browser')
            finally:
                browser('close')
    finally:
        for ident in identifiers:
            cli('--stop-project', ident, check=False)
