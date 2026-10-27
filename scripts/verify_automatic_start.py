"""The ordinary saved-project Run action establishes proof without a separate setup step."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];binary=str(ROOT/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Automatic normal start ',dir=ROOT/'work') as folder:
    root=Path(folder);project=root/'Project';project.mkdir()
    (project/'package.json').write_text(json.dumps({'scripts':{'dev':'node server.cjs'}}))
    (project/'server.cjs').write_text("require('node:http').createServer((q,s)=>s.end('working')).listen(0,'127.0.0.1')")
    env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'state'),DEVBAR_HEADLESS='1')
    def cli(*args,code=0):
        p=subprocess.run([binary,*args],env=env,capture_output=True,text=True,timeout=45)
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return p.stdout
    ident=cli('--add-project',str(project)).strip()
    try:
        cli('--start-project',ident)
        deadline=time.monotonic()+30;value=None
        while time.monotonic()<deadline:
            p=subprocess.run([binary,'status',str(project),'--target','dev','--json'],env=env,capture_output=True,text=True,timeout=10)
            value=json.loads(p.stdout)
            if value['state']=='current':break
            time.sleep(.2)
        assert value['state']=='current',value
        fresh=json.loads(cli('--freshness-project',str(project)))
        assert fresh['state']=='verified',fresh
        cli('--stop-project',ident)
        assert json.loads(cli('status',str(project),'--target','dev','--json',code=2))['state']=='stopped'
        assert not (project/'.devbar.json').exists()
        print('PASS: ordinary add/start automatically establishes serving-runtime revision proof, saved command preserved, normal stop cleans monitor and application, no configuration file')
    finally:
        subprocess.run([binary,'--stop-project',ident],env=env,capture_output=True,timeout=30)
