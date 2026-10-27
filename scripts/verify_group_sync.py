"""A composite becomes current only when all real member runtimes are verified."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
BINARY=str(ROOT/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Group sync ',dir=ROOT/'work') as folder:
    root=Path(folder);project=root/'project';project.mkdir()
    env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'state'),DEVBAR_HEADLESS='1')
    (project/'package.json').write_text(json.dumps({'scripts':{'dev':'concurrently "npm:dev:frontend" "npm:dev:backend"','dev:frontend':'node frontend.cjs','dev:backend':'node backend.cjs'}}))
    for name in ['frontend','backend']:
        (project/(name+'.cjs')).write_text("require('node:http').createServer((q,s)=>{s.setHeader('Content-Type','text/html');s.end('<html>v1</html>')}).listen(0,'127.0.0.1')")
    def cli(action,*args,code=0):
        p=subprocess.run([BINARY,action,str(project),'--target','dev','--json',*args],env=env,capture_output=True,text=True,timeout=150)
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return json.loads(p.stdout)
    assert cli('sync','--plan')['state']=='planned'
    assert not (root/'state/sync').exists()
    try:
        first=cli('sync');assert first['state']=='current' and len(first['members'])==2
        assert cli('status')['state']=='current'
        (project/'backend.cjs').write_text('process.exit(23)')
        failed=cli('sync',code=1);assert failed['state']=='failed'
        assert cli('status',code=2)['state']!='current'
        (project/'backend.cjs').write_text("require('node:http').createServer((q,s)=>{s.setHeader('Content-Type','text/html');s.end('<html>v2</html>')}).listen(0,'127.0.0.1')")
        assert cli('sync')['state']=='current'
        assert cli('stop')['state']=='stopped'
        assert cli('status',code=2)['state']=='unconfirmed'
        assert not (project/'.devbar.json').exists()
        (project/'.devbar.json').write_text(json.dumps({'targets':{'cycle':{'strategy':'group','members':['cycle']}}}))
        p=subprocess.run([BINARY,'sync',str(project),'--target','cycle','--plan','--json'],env=env,capture_output=True,text=True,timeout=15)
        assert p.returncode==1
        print('PASS: automatic composite, real member proof, all-members readiness, failed-member cleanup/recovery, exact group stop and cycle rejection')
    finally:
        (project/'.devbar.json').unlink(missing_ok=True)
        subprocess.run([BINARY,'stop',str(project),'--target','dev','--json'],env=env,capture_output=True,timeout=30)
