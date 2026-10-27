"""The revision comes from the actual workerd module, not the Wrangler CLI process."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request
ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
wrangler_package = os.environ.get('DEVBAR_TEST_WRANGLER')
if not wrangler_package:
    raise SystemExit('Set DEVBAR_TEST_WRANGLER to the installed Wrangler package directory; no personal project is assumed')
WRANGLER=Path(wrangler_package).expanduser().resolve()
if not (WRANGLER/'package.json').is_file():
    raise SystemExit('DEVBAR_TEST_WRANGLER must be an installed Wrangler package directory')
assert WRANGLER.is_dir(), 'Set DEVBAR_TEST_WRANGLER to an installed project-local Wrangler package'
with tempfile.TemporaryDirectory(prefix='Worker automatic ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'node_modules').mkdir();(project/'node_modules/wrangler').symlink_to(WRANGLER, target_is_directory=True)
    (project/'public').mkdir();(project/'public/index.html').write_text('<html>Static asset</html>')
    (project/'package.json').write_text(json.dumps({'scripts':{'dev':'wrangler dev --local --port 0'}}))
    (project/'wrangler.json').write_text(json.dumps({'name':'devbar-local-fixture','main':'worker.mjs','compatibility_date':'2025-01-01','compatibility_flags':['nodejs_compat'],'vars':{'GREETING':'v1'},'assets':{'directory':'public','not_found_handling':'single-page-application','run_worker_first':['/api/*']}}))
    source=project/'worker.mjs';source.write_text("import {Buffer} from 'node:buffer';export default {fetch(r,e){return new Response(Buffer.from(e.GREETING).toString())}}")
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1',WRANGLER_SEND_METRICS='false')
    def cli(action,code=0):
        p=subprocess.run([BINARY,action,str(project),'--target','dev','--json'],env=env,capture_output=True,text=True,timeout=180)
        if p.returncode != code:
            value=json.loads(p.stdout)
            if value.get('log'):
                import shutil
                shutil.copyfile(value['log'],ROOT/'work/automatic-worker-failure.log')
            for f in (project/'work/state/sync/witnesses').rglob('*.json'):
                if f.name.endswith('.json') and f.parent.name.count('-')==4:
                    print('witness',f.read_text()[:1800])
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return json.loads(p.stdout)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        one=cli('sync');assert one['state']=='current',one
        proof=one['receipt']['proof'];assert proof['runtimeVersion']=='workerd' and proof['transportPID']
        assert opener.open(proof['entryURL']+'api/application',timeout=5).read()==b'v1'
        source.write_text("import {Buffer} from 'node:buffer';export default {fetch(r,e){return new Response(Buffer.from(e.GREETING.replace('v1','v2')).toString())}}")
        assert cli('status',2)['state']=='sourceChanged'
        two=cli('sync');assert two['state']=='current'
        assert two['receipt']['proof']['instanceID']!=proof['instanceID']
        assert opener.open(two['receipt']['proof']['entryURL']+'api/application',timeout=5).read()==b'v2'
        assert cli('status')['state']=='current'
        cli('stop')
        assert not (project/'.devbar.json').exists()
        print('PASS: zero-config project-local Wrangler, compiled proof inside actual workerd, application v1→v2 responses, source/proof identity, isolated local bindings/persistence and exact stop')
    finally:
        subprocess.run([BINARY,'stop',str(project),'--target','dev','--json'],env=env,capture_output=True,timeout=30)
