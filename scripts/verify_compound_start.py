"""Named and inline concurrently commands become real managed members, without that CLI."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];binary=str(ROOT/'.build/release/DevBar')
vite=Path(os.environ['DEVBAR_TEST_VITE']).resolve()
with tempfile.TemporaryDirectory(prefix='Compound start ',dir=ROOT/'work') as folder:
    base=Path(folder);project=base/'Project';(project/'node_modules/.bin').mkdir(parents=True)
    (project/'node_modules/vite').symlink_to(vite,target_is_directory=True)
    (project/'node_modules/.bin/vite').symlink_to(vite/'bin/vite.js')
    (project/'package.json').write_text(json.dumps({'scripts':{'dev':'concurrently -n "api,web" "npm run server" "vite --port 0 --host 127.0.0.1"','server':'node server.cjs'},'dependencies':{'vite':'*'}}))
    (project/'index.html').write_text('<html><title>Compound frontend</title></html>')
    (project/'server.cjs').write_text("require('node:http').createServer((q,s)=>s.end('API')).listen(0,'127.0.0.1')")
    env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'),DEVBAR_HEADLESS='1')
    def cli(*args,code=0):
        p=subprocess.run([binary,*args],env=env,capture_output=True,text=True,timeout=60)
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return p.stdout
    ident=cli('--add-project',str(project)).strip()
    try:
        cli('--start-project',ident)
        deadline=time.monotonic()+40;status=None
        while time.monotonic()<deadline:
            p=subprocess.run([binary,'status',str(project),'--target','dev','--json'],env=env,capture_output=True,text=True,timeout=15)
            status=json.loads(p.stdout)
            if status['state']=='current':break
            time.sleep(.2)
        assert status['state']=='current' and len(status['members'])==2,status
        assert json.loads(cli('--freshness-project',str(project)))['state']=='verified'
        cli('--stop-project',ident)
        assert json.loads(cli('status',str(project),'--target','dev','--json',code=2))['state']=='unconfirmed'
        assert not (project/'.devbar.json').exists()
        print('PASS: ordinary Run handles real named backend + inline Vite, no concurrently install/configuration, all-member runtime proof, shared UI freshness and normal stop')
    finally:
        subprocess.run([binary,'--stop-project',ident],env=env,capture_output=True,timeout=30)
