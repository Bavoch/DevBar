from pathlib import Path
import subprocess,socket,time,os,json,urllib.request,argparse
ROOT=Path(__file__).resolve().parents[1];results=[]
parser=argparse.ArgumentParser(description='Run an explicitly selected local VitePress project on an isolated port')
parser.add_argument('projects', nargs='+', help='VitePress project directories with dependencies installed')
args=parser.parse_args()
(ROOT/'work').mkdir(exist_ok=True)
for argument in args.projects:
 root=str(Path(argument).expanduser().resolve(strict=True))
 if not (Path(root)/'node_modules/vitepress/bin/vitepress.js').is_file():
  raise SystemExit('Selected project has no installed VitePress entry')
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 log=ROOT/'work'/('vitepress-'+str(port)+'.log')
 with log.open('w') as f:
  p=subprocess.Popen(['node',root+'/node_modules/vitepress/bin/vitepress.js','dev','docs','--host','127.0.0.1','--port',str(port)],cwd=root,stdout=f,stderr=f,start_new_session=True)
  try:
   opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
   for _ in range(70):
    try:
     with opener.open(f'http://127.0.0.1:{port}',timeout=2) as r:
      content=r.read();assert r.status==200 and b'<html' in content.lower()
     results.append({'project':root,'serverHTTP':200,'passed':True});break
    except Exception:time.sleep(.2)
   else:raise RuntimeError(log.read_text()[-3000:])
  finally:os.killpg(p.pid,15);p.wait(timeout=10)
(ROOT/'work/vitepress-evidence.json').write_text(json.dumps(results,indent=2));print(json.dumps(results))
