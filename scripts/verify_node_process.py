"""A non-HTTP watcher must prove the actual loaded entry, not merely an alive npm."""
from pathlib import Path
import os,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='Node process ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'scripts').mkdir()
    (project/'package.json').write_text(json.dumps({'type':'module','scripts':{'dev:backend':'node scripts/watch.mjs'}}))
    source=project/'scripts/watch.mjs'
    source.write_text("import {writeFile,mkdir} from 'node:fs/promises';process.env.DEVBAR_SOURCE_DIGEST='WRONG';await mkdir('work',{recursive:true});while (true){await writeFile('work/result','v1');await new Promise(r=>setTimeout(r,100));}")
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1')
    def cli(action,code=0):
        p=subprocess.run([BINARY,action,str(project),'--target','dev:backend','--json'],env=env,capture_output=True,text=True,timeout=180)
        if p.returncode != code:
            value=json.loads(p.stdout)
            if value.get("log"): print(Path(value["log"]).read_text()[-5000:])
        assert p.returncode==code,(p.stdout,p.stderr)
        return json.loads(p.stdout)
    try:
        one=cli('sync');assert one['state']=='current'
        assert one['receipt']['proof']['runtimeVersion']=='nodeProcess'
        assert (project/'work/result').read_text()=='v1'
        assert cli('status')['state']=='current'
        source.write_text(source.read_text().replace('v1','v2'))
        assert cli('status',2)['state']=='sourceChanged'
        two=cli('sync');assert two['state']=='current'
        assert two['receipt']['proof']['sourceDigest']!='WRONG'
        assert (project/'work/result').read_text()=='v2'
        cli('stop');assert cli('status',2)['state']=='stopped'
        print('PASS: actual ESM watcher source loaded, independent in-process proof, real job v1→v2 output, source change invalidation and exact stop')
    finally:subprocess.run([BINARY,'stop',str(project),'--target','dev:backend','--json'],env=env,capture_output=True,timeout=30)
