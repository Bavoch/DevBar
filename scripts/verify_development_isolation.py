"""Framework-neutral startup contract. No windows, browser or permission changes."""
from pathlib import Path
import hashlib, json, os, subprocess, sys, tempfile, time
ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('DEVBAR_TEST_BINARY', ROOT / '.build/release/DevBar')).resolve()
def wait(read, message, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if value := read(): return value
        except (OSError, ValueError, KeyError, StopIteration): pass
        time.sleep(.1)
    raise AssertionError(message)
def alive(pid):
    text = subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
    return bool(text) and 'Z' not in text
with tempfile.TemporaryDirectory(prefix='Development contract ',dir=ROOT/'work') as folder:
    base=Path(folder); state=base/'state'; ids=[]
    env=dict(os.environ,DEVBAR_DATA_DIR=str(state),
        CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER='project-owned-runner --debug',
        DEVBAR_DEVELOPMENT_SIGN_IDENTITY='must-not-be-used',
        __CFBundleIdentifier='local.devbar.must-not-inherit',PROJECT_MARKER='original-value')
    # Exercise ordinary Start, without the old test-only background switch.
    env.pop('DEVBAR_HEADLESS', None)
    def cli(*args,check=True):
        return subprocess.run([str(BINARY),*map(str,args)],env=env,capture_output=True,text=True,check=check,timeout=35)
    def session(project, ident):
        run=json.loads(next(state.glob(ident+'.target-*.run.json')).read_text())
        key=hashlib.sha256((str(project)+'\n'+run['targetID']).encode()).hexdigest()
        return json.loads((state/'development'/(key+'.json')).read_text())
    try:
        for framework in ('tauri','electron-vite','vite','custom-tool'):
            project=base/framework; project.mkdir()
            source=project/'source.txt'; source.write_text('before')
            witness=base/(framework+'.json')
            tool=project/'node_modules/.bin'/framework; tool.parent.mkdir(parents=True)
            tool.write_text('#!'+sys.executable+'\n'+f'''
import json,os,pathlib,sys,time
source=pathlib.Path({str(source)!r}); witness=pathlib.Path({str(witness)!r})
last=None; count=0
while True:
 value=source.read_text()
 if value!=last:
  last=value; count+=1
  report=dict(pid=os.getpid(),args=sys.argv[1:],cwd=os.getcwd(),value=value,count=count,
    runner=os.environ.get('CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER'),
    marker=os.environ.get('PROJECT_MARKER'),bundle=os.environ.get('__CFBundleIdentifier'))
  temp=witness.with_suffix('.tmp');temp.write_text(json.dumps(report));temp.replace(witness)
  print('reload:'+value,flush=True)
 time.sleep(.05)
''')
            tool.chmod(0o700)
            (project/'package.json').write_text(json.dumps({'scripts':{'dev':framework+' dev --project-flag'}}))
            (project/'src-tauri/.cargo').mkdir(parents=True)
            (project/'src-tauri/tauri.conf.json').write_text('{"identifier":"local.project.original"}')
            (project/'src-tauri/.cargo/config.toml').write_text('[target.aarch64-apple-darwin]\nrunner="original-runner"\n')
            app=project/'Original.app/Contents/MacOS/app'; app.parent.mkdir(parents=True)
            app.write_bytes(b'original signed artifact'); (app.parent.parent/'Info.plist').write_bytes(b'original identity')
            protected=[project/'package.json',project/'src-tauri/tauri.conf.json',project/'src-tauri/.cargo/config.toml',app,app.parent.parent/'Info.plist']
            before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
            ident=cli('--add-project',project,'--command','npm run dev').stdout.strip(); ids.append(ident)
            cli('--start-project',ident)
            first=wait(lambda:json.loads(witness.read_text()),framework+' failed to start')
            assert first['args']==['dev','--project-flag'] and first['cwd']==str(project),first
            assert first['runner']==env['CARGO_TARGET_AARCH64_APPLE_DARWIN_RUNNER'],first
            assert first['marker']=='original-value' and first['bundle'] is None,first
            child=wait(lambda:session(project,ident).get('child'),'Missing command identity')
            assert child['parent']==1 and child['launchID'] and child['pid']==child['group']
            assert not any(state.glob('tasks/*/terminal')), 'Ordinary Start opened a Terminal task'
            source.write_text('after')
            after=wait(lambda:(r if (r:=json.loads(witness.read_text()))['value']=='after' else None),'Reload lost')
            assert after['pid']==first['pid'] and after['count']==2,after
            assert before=={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in protected}
            assert not any((state/name).exists() for name in ('development-apps','development-runners','native-development'))
            wait(lambda:'reload:after' in (state/(ident+'.log')).read_text(),'Logs lost')
            cli('--stop-project',ident); wait(lambda:not alive(first['pid']),'Command survived Stop')
            print(f'PASS: {framework} args/cwd/env/custom runner/artifacts preserved; project-owned reload; independent stop',flush=True)
        project=base/'unwatched'; project.mkdir(); source=project/'main.py'; witness=base/'unwatched.json'
        source.write_text(f'import os,pathlib,time\npathlib.Path({str(witness)!r}).write_text(str(os.getpid()))\nwhile True:time.sleep(.1)\n')
        (project/'package.json').write_text(json.dumps({'scripts':{'dev':sys.executable+' main.py'}}))
        ident=cli('--add-project',project,'--command','npm run dev').stdout.strip(); ids.append(ident)
        cli('--start-project',ident); pid=wait(lambda:int(witness.read_text()),'No command')
        source.write_text(source.read_text()+'# source changed\n'); time.sleep(1.5)
        assert int(witness.read_text())==pid and alive(pid),'DevBar injected reload'
        cli('--stop-project',ident); source.write_text('import sys\nsys.exit(4)\n'); cli('--start-project',ident)
        failed=wait(lambda:(r if (r:=session(project,ident))['phase']=='failed' else None),'Failure missing')
        wait(lambda:not alive(failed['supervisor']['pid']),'Hidden failure supervisor retained')
        run=json.loads(next(state.glob(ident+'.target-*.run.json')).read_text())
        receipt=state/'tasks'/run['launchID']/'exit'; wait(receipt.exists,'Missing exit receipt')
        assert receipt.read_text().strip()=='4','Actual exit code lost'
        print('PASS: no injected watcher/retry or fabricated running state; original exit code retained',flush=True)
    finally:
        for ident in ids: cli('--stop-project',ident,check=False)
