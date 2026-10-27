"""Adopt only a matching real Vite command; a foreign occupied port gets an isolated fallback."""
from pathlib import Path
import json,os,socket,subprocess,tempfile,time,urllib.request
ROOT=Path(__file__).resolve().parents[1];binary=str(ROOT/'.build/release/DevBar')
vite=Path(os.environ['DEVBAR_TEST_VITE']).resolve()
node=subprocess.check_output(['/bin/zsh','-lc','command -v node'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='Frontend adoption ',dir=ROOT/'work') as folder:
    base=Path(folder);env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'),DEVBAR_HEADLESS='1',BROWSER='none',DEVBAR_ALLOW_EXTERNAL_RESTART='1')
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    def project(name,strict=False):
        p=base/name;(p/'node_modules/.bin').mkdir(parents=True)
        (p/'node_modules/vite').symlink_to(vite,target_is_directory=True)
        (p/'node_modules/.bin/vite').symlink_to(vite/'bin/vite.js')
        (p/'package.json').write_text(json.dumps({'scripts':{'dev':f'vite --port {port}'+(' --strictPort' if strict else '')},'dependencies':{'vite':'*'}}))
        (p/'index.html').write_text('<!doctype html><html><title>Actual frontend</title></html>')
        return p
    def cli(action,p):
        r=subprocess.run([binary,action,str(p),'--target','dev','--json'],env=env,capture_output=True,text=True,timeout=150)
        assert r.returncode==0,(r.stdout,r.stderr)
        return json.loads(r.stdout)
    first=project('First');second=project('Second',True)
    external=subprocess.Popen([node,str(first/'node_modules/.bin/vite'),'--port',str(port)],cwd=first,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        for _ in range(80):
            try:opener.open(f'http://127.0.0.1:{port}',timeout=1).close();break
            except Exception:time.sleep(.1)
        adopted=cli('sync',first);assert adopted['state']=='current'
        external.wait(timeout=10)
        fallback=cli('sync',second);assert fallback['state']=='current'
        assert '--port 0' in fallback['receipt']['executionCommand']
        assert f':{port}/' not in fallback['receipt']['proof']['entryURL']
        assert b'Actual frontend' in opener.open(fallback['receipt']['proof']['entryURL'],timeout=5).read()
        assert cli('status',first)['state']=='current'
        cli('stop',second);assert cli('status',first)['state']=='current'
        cli('stop',first)
        print('PASS: verified external Vite command adoption/restart, exact cwd/user/identity, foreign port collision fallback, actual HTML, independent target stop and no project config')
    finally:
        for p in [first,second]:subprocess.run([binary,'stop',str(p),'--target','dev','--json'],env=env,capture_output=True,timeout=30)
        if external.poll() is None:external.terminate();external.wait(timeout=10)
