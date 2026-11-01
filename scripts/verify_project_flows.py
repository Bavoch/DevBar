"""Real language runtimes and outside-CWD launch attribution, with isolated state."""
from pathlib import Path
import json
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))

def until(check, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, StopIteration):
            pass
        time.sleep(.2)
    raise AssertionError('Project did not reach expected state')

with tempfile.TemporaryDirectory(prefix='Project flows ', dir=ROOT/'work') as folder:
    base = Path(folder)
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base/'state'), DEVBAR_HEADLESS='1')
    identifiers = []
    external = None
    def cli(*args, check=True):
        result = subprocess.run([BINARY, *args], env=env, text=True, capture_output=True, timeout=60)
        if check: assert result.returncode == 0, result.stdout + result.stderr
        return result
    def row(project):
        return next(p for p in json.loads(cli('--menu-json').stdout) if p.get('value') == str(project))
    def running(project):
        return any(p.get('action') == 'stopProject:' for p in row(project)['items'])
    def make(name, files):
        project = base/name
        project.mkdir()
        for name, content in files.items():
            file = project/name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(content)
        return project
    def add(project):
        identifier = cli('--add-project', str(project)).stdout.strip()
        identifiers.append(identifier)
        return identifier
    try:
        source = 'import os,time\nopen("runtime.pid","w").write(str(os.getpid()))\nwhile True: time.sleep(1)\n'
        project = make('Python with spaces', {'pyproject.toml':'[project]\nname="fixture"\nversion="1"\n', 'main.py':source})
        other = make('Wrong working directory', {'package.json':'{}'})
        identifier = add(project)
        external = subprocess.Popen([sys.executable, str(project/'main.py')], cwd=other,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until(lambda: (other/'runtime.pid').exists())
        until(lambda: running(project))
        scan = json.loads(cli('--scan-json').stdout)
        owned = next(p for p in scan if p['path'] == str(project))
        assert any(p['pid'] == external.pid for p in owned['controlProcesses']), owned
        (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'service':{
            'strategy':'process','startCommand':shlex.quote(sys.executable)+' main.py'}}}))
        status = cli('status', str(project), '--target', 'service', '--json')
        assert json.loads(status.stdout)['state'] == 'current', status.stdout
        assert json.loads(cli('sync', str(project), '--target', 'service', '--json').stdout)['state'] == 'current'
        assert external.poll() is None, 'Idempotent sync replaced the existing runtime'
        cli('--stop-project', identifier)
        external.wait(timeout=10)
        assert not running(project)
        print('PASS: absolute Python script with spaces belongs to its source project, independent of launcher CWD', flush=True)
        entry = project/'.venv/bin/fixture'
        entry.parent.mkdir(parents=True)
        entry.write_text('#!'+sys.executable+'\n'+source)
        entry.chmod(0o700)
        external = subprocess.Popen([str(entry)], cwd=other, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until(lambda: running(project))
        cli('--stop-project', identifier)
        external.wait(timeout=10)
        print('PASS: virtual-environment entry without a file extension is discovered and controlled from another directory', flush=True)
        (project/'.devbar.json').unlink()
        cli('--select-target', identifier, '--target', 'file:main.py')
        (project/'main.py').rename(project/'run.py')
        rejected = cli('--start-project', identifier, check=False)
        assert rejected.returncode != 0 and '重新选择' in rejected.stderr
        more = next(p['items'] for p in row(project)['items'] if p['title'] == '更多')
        choices = next(p['items'] for p in more if p['title'] == '运行方式')
        assert len(choices) == 1, choices
        cli('--select-target', identifier, '--target', 'file:run.py')
        print('PASS: a removed running method can be replaced even when only one new method remains', flush=True)

        cases = [
            ('Swift', 'swift', {
                'Package.swift':'// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name:"FlowFixture", products:[.executable(name:"FlowFixture",targets:["FlowFixture"])],targets:[.executableTarget(name:"FlowFixture")])\n',
                'Sources/FlowFixture/main.swift':'import Foundation\ntry! String(ProcessInfo.processInfo.processIdentifier).write(toFile:"runtime.pid",atomically:true,encoding:.utf8)\nwhile true { Thread.sleep(forTimeInterval:1) }\n'}),
            ('Rust', 'cargo', {'Cargo.toml':'[package]\nname="flow_fixture"\nversion="0.1.0"\nedition="2021"\n',
                'src/main.rs':'fn main(){std::fs::write("runtime.pid",std::process::id().to_string()).unwrap();loop{std::thread::sleep(std::time::Duration::from_secs(1));}}'}),
            ('Go', 'go', {'go.mod':'module local.devbar/flowfixture\n\ngo 1.20\n',
                'main.go':'package main\nimport("os";"strconv";"time")\nfunc main(){os.WriteFile("runtime.pid",[]byte(strconv.Itoa(os.Getpid())),0600);for{time.Sleep(time.Second)}}\n'}),
        ]
        for name, tool, files in cases:
            assert shutil.which(tool), 'Missing test tool: '+tool
            project = make(name+' program', files)
            identifier = add(project)
            cli('--start-project', identifier)
            until(lambda: (project/'runtime.pid').exists())
            until(lambda: running(project))
            first = int((project/'runtime.pid').read_text())
            cli('--restart-project', identifier)
            until(lambda: int((project/'runtime.pid').read_text()) != first)
            until(lambda: running(project))
            cli('--stop-project', identifier)
            assert not running(project), name+' remained running after Stop'
            print('PASS: real '+name+' compile, run, project restart and stop', flush=True)

        project = make('Delayed webpage', {'package.json': json.dumps({'scripts':{'dev:web':shlex.quote(sys.executable)+' server.py'}}),
            'server.py':'import time,http.server\ntime.sleep(5)\nhttp.server.HTTPServer(("127.0.0.1",0),http.server.SimpleHTTPRequestHandler).serve_forever()\n'})
        identifier = add(project)
        target = json.loads(cli('--profile-project', str(project)).stdout)['targets'][0]['id']
        cli('--start-project', identifier)
        state = base/'state/development'/(hashlib.sha256((str(project)+'\n'+target).encode()).hexdigest()+'.json')
        until(state.exists)
        assert json.loads(state.read_text())['phase'] == 'starting'
        until(lambda: json.loads(state.read_text())['phase'] == 'watching')
        cli('--stop-project', identifier)
        print('PASS: web startup stays starting until its HTTP endpoint responds', flush=True)

        # Simulate a menu-bar PATH with Node installed only through nvm.
        nvm = base/'nvm'
        nodebin = nvm/'versions/node/v42.1.0/bin'
        nodebin.mkdir(parents=True)
        (nvm/'alias').mkdir()
        (nvm/'alias/default').write_text('42\n')
        node = nodebin/'node'
        node.write_text('#!/bin/sh\necho $$ > "$DEVBAR_PROJECT_PATH/runtime.pid"\nexec /bin/sleep 120\n')
        node.chmod(0o700)
        npm = nodebin/'npm'
        npm.write_text('#!/bin/sh\nexec node server.js\n')
        npm.chmod(0o700)
        (nvm/'nvm.sh').write_text('export PATH=/usr/bin:/bin\nnvm() { export PATH="$NVM_DIR/versions/node/v42.1.0/bin:/usr/bin:/bin"; }\n')
        env['NVM_DIR'] = str(nvm)
        for pinned in (False, True):
            files = {'package.json':json.dumps({'scripts':{'dev':'node server.js'}}), 'server.js':'// fixture\n'}
            if pinned: files['.nvmrc'] = '42\n'
            project = make('Node pinned' if pinned else 'Node default', files)
            identifier = add(project)
            cli('--start-project', identifier)
            until(lambda: (project/'runtime.pid').exists())
            cli('--stop-project', identifier)
        env.pop('NVM_DIR')
        print('PASS: menu-bar startup resolves nvm default and project-pinned Node without global environment changes', flush=True)
    finally:
        for identifier in identifiers:
            cli('--stop-project', identifier, check=False)
        if external is not None and external.poll() is None:
            external.terminate()
            external.wait(timeout=10)
