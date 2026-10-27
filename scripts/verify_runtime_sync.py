"""Real managed HTTP services and independent host adapter; never open a browser window."""
from pathlib import Path
import json, os, signal, socket, subprocess, tempfile, time, urllib.request

ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
with tempfile.TemporaryDirectory(prefix='Runtime sync # with spaces ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'work').mkdir()
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'))
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    url=f'http://127.0.0.1:{port}/.well-known/devbar.json'
    (project/'revision.txt').write_text('v1')
    (project/'server.py').write_text('''import http.server,json,os,pathlib
root=pathlib.Path(__file__).parent
revision=(root/'revision.txt').read_text()
proof={k:os.environ.get(e,'external') for k,e in [('sourceDigest','DEVBAR_SOURCE_DIGEST'),('syncID','DEVBAR_SYNC_ID'),('target','DEVBAR_SYNC_TARGET')]}
proof.update(instanceID=str(os.getpid()),revision=revision)
(root/'work/pid').write_text(str(os.getpid()))
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=json.dumps(proof).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
class Server(http.server.HTTPServer):allow_reuse_address=True
Server(('127.0.0.1',PORT),Handler).serve_forever()
'''.replace('PORT',str(port)))
    config=project/'.devbar.json'
    target={'strategy':'process','startCommand':'python3 server.py','proofURL':url,'timeout':8,'sourcePaths':['server.py','revision.txt','.devbar.json']}
    def save(targets=None): config.write_text(json.dumps({'schemaVersion':1,'targets':targets or {'web':target}}))
    def cli(action,*options,code=0):
        r=subprocess.run([BINARY,action,str(project),'--json',*options],capture_output=True,text=True,env=env,timeout=40)
        assert r.returncode==code,(r.returncode,r.stdout,r.stderr)
        value=json.loads(r.stdout);assert value['schemaVersion']==1
        return value
    def loaded(): return json.load(opener.open(url,timeout=2))
    def cleanup():
        if (project/'work/pid').exists():
            try:os.kill(int((project/'work/pid').read_text()),signal.SIGTERM)
            except ProcessLookupError:pass
    try:
        save()
        assert cli('sync','--plan')['state']=='planned'
        assert not (project/'work/pid').exists()
        added=subprocess.check_output([BINARY,'--add-project',str(project),'--command','python3 server.py'],env=env,text=True).strip()
        subprocess.run([BINARY,'--start-project',added],env=env,check=True,capture_output=True)
        for _ in range(50):
            try:
                if loaded()['syncID']=='external':break
            except Exception:time.sleep(.1)
        else:raise AssertionError('Original DevBar managed instance did not start')
        first=cli('sync');assert first['state']=='current'
        pid=first['receipt']['process']['pid'];assert loaded()['revision']=='v1'
        descriptors=subprocess.run(['lsof','-p',loaded()['instanceID']],capture_output=True,text=True).stdout
        assert not any(str(project/'work/state') in line and line.rstrip().endswith('.lock') for line in descriptors.splitlines()), 'Runtime must not inherit store/sync lock descriptors'
        assert cli('status')['state']=='current'
        assert cli('stop','--plan',code=1)['state']=='setupRequired'
        assert cli('status')['state']=='current', 'Unsupported flags must never stop the process'
        assert cli('sync')['receipt']['process']['pid']==pid
        os.utime(project/'revision.txt',None);assert cli('status')['state']=='current'
        (project/'revision.txt').write_text('v2')
        assert cli('status',code=2)['state']=='sourceChanged'
        second=cli('sync');assert second['receipt']['process']['pid']!=pid and loaded()['revision']=='v2'
        target['buildCommand']='exit 12';save()
        assert cli('sync',code=1)['state']=='failed' and loaded()['revision']=='v2'
        del target['buildCommand'];save()
        assert cli('sync')['state']=='current'
        assert cli('stop')['state']=='stopped'
        assert cli('status',code=2)['state']=='stopped'
        del target['proofURL'];save()
        unverified=cli('sync',code=2)
        assert unverified['state']=='runningUnverified'
        assert cli('status',code=2)['state']=='runningUnverified'
        assert cli('sync',code=2)['receipt']['process']['pid']==unverified['receipt']['process']['pid']
        cli('stop')
        target['proofURL']=url
        with socket.socket() as sock: sock.bind(('127.0.0.1',0));port2=sock.getsockname()[1]
        (project/'server2.py').write_text((project/'server.py').read_text().replace(str(port),str(port2)))
        other=dict(target,startCommand='python3 server2.py',proofURL=f'http://127.0.0.1:{port2}/.well-known/devbar.json',sourcePaths=['server2.py','revision.txt','.devbar.json'])
        save({'one':target,'two':other})
        assert cli('sync',code=1)['state']=='setupRequired', 'Multi-target must not choose silently'
        assert cli('sync','--target','one')['state']=='current'
        assert cli('sync','--target','two')['state']=='current', 'Managed sibling targets must coexist'
        assert cli('status','--target','one')['state']=='current'
        cli('stop','--target','two')
        assert cli('status','--target','one')['state']=='current', 'Stopping a sibling must not stop this target'
        cli('stop','--target','one')
        target['proofURL']='https://example.com/proof';save()
        assert cli('sync','--plan',code=1)['state']=='setupRequired'
        target['proofURL']=url;save()
        (project/'probe.py').write_text('import urllib.request,sys;print("probe diagnostics",file=sys.stderr);print(urllib.request.urlopen('+repr(url)+',timeout=2).read().decode())')
        (project/'deploy.py').write_text('''import os,pathlib,signal,subprocess,sys
root=pathlib.Path(__file__).parent
pid=root/'work/pid'
if pid.exists():
 try:os.kill(int(pid.read_text()),signal.SIGTERM)
 except ProcessLookupError:pass
subprocess.Popen([sys.executable,str(root/'server.py')],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
''')
        target={'strategy':'external','syncCommand':'python3 deploy.py','proofCommand':'python3 probe.py','sourcePaths':['server.py','revision.txt','probe.py','deploy.py','.devbar.json'],'timeout':8}
        save()
        external=cli('sync');assert external['state']=='current' and loaded()['revision']=='v2'
        assert cli('status')['state']=='current'
        (project/'revision.txt').write_text('v3')
        external=cli('sync');assert external['state']=='current' and loaded()['revision']=='v3'
        config.write_text(json.dumps({'schemaVersion':999,'targets':{'web':target}}))
        assert cli('sync',code=1)['state']=='setupRequired'
        print('PASS: actual managed HTTP process v1→v2, runtime digest/token/instance proof, idempotence, build failure preservation, strict unverified state, exact stop, ambiguous target/schema/remote-proof rejection, independent external host v2→v3')
    finally:cleanup()
