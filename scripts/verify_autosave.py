"""Discover an externally started fixture, persist it, and honor manual removal."""
import concurrent.futures
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Auto saved ', dir=root / 'work') as tmp:
    base = pathlib.Path(tmp)
    project = base / 'External project'
    project.mkdir()
    (project / 'package.json').write_text(json.dumps({'scripts':{'dev':'touch MUST_NOT_RUN'},'packageManager':'pnpm@10'}))
    (project / 'run.py').write_text('import time; time.sleep(180)\n')
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state))
    process = subprocess.Popen([sys.executable,str(project / 'run.py')],cwd=project,start_new_session=True)
    def cli(*args, check=True):
        return subprocess.run([binary,*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,check=check,timeout=40)
    def sync():
        return json.loads(cli('--remember-running','--project',str(project)).stdout)
    try:
        time.sleep(.2)
        # Inspection remains read-only; imports happen only on the application's persistence path.
        cli('--scan-json')
        assert not (state / 'projects.json').exists()
        entries = sync()
        assert len(entries)==1 and entries[0]['path']==str(project)
        assert entries[0]['command']=='pnpm run dev'
        identity = entries[0]['id']
        assert not (project / 'MUST_NOT_RUN').exists()
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(lambda _: sync(), range(3)))
        assert all(len(r)==1 and r[0]['id']==identity for r in results)
        assert (state / 'projects.json').stat().st_mode & 0o777 == 0o600
        print('PASS: external portless project automatically persists once; concurrent imports deduplicate; no script execution')
        config = json.loads((state / 'projects.json').read_text())
        config[0]['name']='Custom name'; config[0]['command']='custom command'
        (state / 'projects.json').write_text(json.dumps(config))
        assert sync()[0]['name']=='Custom name' and sync()[0]['command']=='custom command'
        process.terminate(); process.wait(timeout=5)
        assert json.loads(cli('--list-projects').stdout)[0]['id']==identity
        menu = json.loads(cli('--menu-json').stdout)
        saved = next(r for r in menu if r['title']=='Custom name')
        assert any(r.get('action')=='startProject:' for r in saved['items'])
        print('PASS: custom name/command preserved; external stop and fresh process keep the project available to run')
        process = subprocess.Popen([sys.executable,str(project / 'run.py')],cwd=project,start_new_session=True)
        time.sleep(.2)
        cli('--remove-project',identity)
        assert sync()==[], 'A running removed project must not be imported again'
        new_id = cli('--add-project',str(project),'--command','pnpm run dev').stdout.strip()
        assert sync()[0]['id']==new_id
        assert str(project) not in json.loads((state / 'excluded-projects.json').read_text())
        # An unknown startup command can still be remembered without inventing executable text.
        (project / 'package.json').write_text('{}')
        cli('--remove-project',new_id)
        cli('--add-project',str(project),'--command','')
        assert sync()[0]['command']==''
        print('PASS: removal opt-out survives refresh; manual add opts back in; unknown commands remain empty')
        (state / 'projects.json').write_text('{invalid')
        assert cli('--remember-running','--project',str(project),check=False).returncode!=0
        assert (state / 'projects.json').read_text()=='{invalid'
        print('PASS: malformed saved configuration is never overwritten by automatic persistence')
    finally:
        if process.poll() is None:
            process.terminate();process.wait(timeout=5)
