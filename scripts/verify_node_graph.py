"""Project preflight stays intact; every independently serving child must be proved."""
from pathlib import Path
import json, os, subprocess, tempfile, urllib.request
ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
wrangler_package = os.environ.get('DEVBAR_TEST_WRANGLER')
if not wrangler_package:
    raise SystemExit('Set DEVBAR_TEST_WRANGLER to the installed Wrangler package directory; no personal project is assumed')
WRANGLER=Path(wrangler_package).expanduser().resolve()
if not (WRANGLER/'package.json').is_file():
    raise SystemExit('DEVBAR_TEST_WRANGLER must be an installed Wrangler package directory')
with tempfile.TemporaryDirectory(prefix='Node orchestration ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'scripts').mkdir();(project/'node_modules').mkdir()
    (project/'node_modules/wrangler').symlink_to(WRANGLER,target_is_directory=True)
    (project/'package.json').write_text(json.dumps({'type':'module','scripts':{'dev':'node scripts/dev.mjs'}}))
    (project/'wrangler.json').write_text(json.dumps({'name':'devbar-graph-fixture','main':'worker.mjs','compatibility_date':'2025-01-01'}))
    source=project/'worker.mjs';source.write_text("export default {fetch(){return new Response('v1')}}")
    (project/'server.mjs').write_text("import http from 'node:http';http.createServer((q,s)=>{s.setHeader('Content-Type','text/html');s.end('<html>frontend</html>')}).listen(0,'127.0.0.1');")
    (project/'scripts/dev.mjs').write_text("import {spawn} from 'node:child_process';import fs from 'node:fs';if(!fs.existsSync('ready'))process.exit(7);spawn(process.execPath,['server.mjs'],{stdio:'inherit'});spawn('npx',['wrangler','dev','--local','--port','0'],{stdio:'inherit',shell:true});")
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1',BROWSER='none',WRANGLER_SEND_METRICS='false')
    def cli(action,success=True):
        p=subprocess.run([BINARY,action,str(project),'--target','dev','--json'],env=env,capture_output=True,text=True,timeout=180)
        value=json.loads(p.stdout)
        if (p.returncode==0)!=success:
            if value.get('log'):print(Path(value['log']).read_text()[-4000:])
            print('graph',[(f.name,f.read_text()) for f in (project/'work/state').rglob('graph/*.json')])
        assert (p.returncode==0)==success,value
        return value
    try:
        assert cli('sync',False)['state']=='failed' # Must not bypass preflight.
        (project/'ready').write_text('ok')
        one=cli('sync');assert one['state']=='current'
        proof=one['receipt']['proof'];assert proof['runtimeVersion']=='nodeGraph'
        assert len(proof['members'])==2,proof
        assert {m['runtimeVersion'] for m in proof['members']}=={'workerd','v'+subprocess.check_output(['node','-p','process.versions.node'],text=True).strip()}
        worker=next(m for m in proof['members'] if m['runtimeVersion']=='workerd')
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        assert opener.open(worker['entryURL'],timeout=5).read()==b'v1'
        assert cli('status')['state']=='current'
        assert cli('sync')['receipt']['syncID']==one['receipt']['syncID']
        source.write_text("export default {fetch(){return new Response('v2')}}")
        assert cli('status',False)['state']=='sourceChanged'
        two=cli('sync');assert two['state']=='current'
        worker=next(m for m in two['receipt']['proof']['members'] if m['runtimeVersion']=='workerd')
        assert opener.open(worker['entryURL'],timeout=5).read()==b'v2'
        # Stop just the serving child: controller and frontend staying alive cannot mean current.
        os.kill(worker['transportPID'],15)
        import time;time.sleep(1)
        assert cli('status',False)['state']=='unconfirmed'
        cli('stop')
        (project/'scripts/dev.mjs').write_text("import {spawn} from 'node:child_process';import fs from 'node:fs';const child=spawn(process.execPath,['server.mjs'],{detached:true,stdio:'ignore'});fs.writeFileSync('work/orphan.pid',String(child.pid));child.unref();setTimeout(()=>process.exit(1),150);")
        assert cli('sync',False)['state']=='failed'
        orphan=int((project/'work/orphan.pid').read_text())
        status=subprocess.run(['/bin/ps','-p',str(orphan),'-o','stat='],capture_output=True,text=True).stdout.strip()
        assert not status or status.startswith('Z'),('Detached child leaked',orphan,status)
        assert not (project/'.devbar.json').exists()
        print('PASS: unchanged ESM project orchestration/preflight, every live child proof, actual workerd + Node, v1→v2, missing sibling invalidation, exact cleanup, no project configuration')
    finally:subprocess.run([BINARY,'stop',str(project),'--target','dev','--json'],env=env,capture_output=True,timeout=30)
