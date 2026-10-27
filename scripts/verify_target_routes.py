"""Verify selected target routing and external-browser stop isolation."""
from pathlib import Path
import json,os,plistlib,signal,subprocess,tempfile,time,urllib.request
root=Path(__file__).resolve().parents[1];binary=str(root/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Target routes ',dir=root/'work') as folder:
 base=Path(folder);env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'))
 def cli(*args,check=True):return subprocess.run([binary,*args],env=env,capture_output=True,text=True,check=check,timeout=45)
 def running(path):return next((p for p in json.loads(cli('--scan-json').stdout) if p['path']==str(path)),None)
 def menu(path):return next(p for p in json.loads(cli('--menu-json').stdout) if p['title']==path.name)['items']
 def until(predicate):
  deadline=time.monotonic()+30
  while time.monotonic()<deadline:
   value=predicate()
   if value:return value
   time.sleep(.2)
  raise AssertionError('Expected target state was not reached')
 project=base/'Desktop and web';project.mkdir();(project/'node_modules').mkdir()
 (project/'package.json').write_text(json.dumps({'scripts':{'dev':'electron .','dev:web':'python3 -m http.server 0 --bind 127.0.0.1'},'devDependencies':{'electron':'1'},'build':{'appId':'local.devbar.routing','productName':'Routing'}}))
 bundle=project/'out/Routing.app/Contents';(bundle/'MacOS').mkdir(parents=True)
 (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.devbar.routing','CFBundleExecutable':'Routing','CFBundlePackageType':'APPL'}))
 (bundle/'MacOS/Routing').write_text('#!/bin/sh\nsleep 120\n');(bundle/'MacOS/Routing').chmod(0o755)
 ident=cli('--add-project',str(project)).stdout.strip()
 try:
  cli('--select-target',ident,'--target','dev:web');cli('--start-project',ident)
  until(lambda: (running(project) or {}).get('entryPoints'))
  p=running(project);assert not p.get('desktop'),p.get('desktop')
  assert any(x['title']=='打开网页' for x in menu(project))
  assert not any(x['title']=='打开应用' for x in menu(project))
  print('PASS: explicit Web target opens webpage even when a verified desktop build exists')
 finally:cli('--stop-project',ident,check=False)
 project=base/'Legacy web command';project.mkdir();(project/'node_modules').mkdir()
 (project/'package.json').write_text(json.dumps({'scripts':{'dev':'python3 -m http.server 0 --bind 127.0.0.1','desktop':'node electron/dev.mjs'},'devDependencies':{'electron':'1'},'build':{'appId':'local.devbar.legacy','productName':'Legacy'}}))
 bundle=project/'out/Legacy.app/Contents';(bundle/'MacOS').mkdir(parents=True)
 (bundle/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.devbar.legacy','CFBundleExecutable':'Legacy','CFBundlePackageType':'APPL'}))
 (bundle/'MacOS/Legacy').write_text('#!/bin/sh\nsleep 120\n');(bundle/'MacOS/Legacy').chmod(0o755)
 ident=cli('--add-project',str(project),'--command','npm run dev').stdout.strip()
 try:
  cli('--start-project',ident);until(lambda:(running(project) or {}).get('entryPoints'))
  assert not running(project).get('desktop')
  assert any(x['title']=='打开网页' for x in menu(project))
  assert next(x for x in json.loads(cli('--list-projects').stdout) if x['id']==ident)['command']=='npm run dev'
  print('PASS: legacy saved web commands keep their command and open the verified webpage instead of an inactive desktop bundle')
 finally:cli('--stop-project',ident,check=False)
 project=base/'Static pages';project.mkdir();(project/'hello #.html').write_text('<title>Chosen page</title>');(project/'other.html').write_text('<title>Other page</title>')
 ident=cli('--add-project',str(project)).stdout.strip()
 try:
  cli('--select-target',ident,'--target','static:hello #.html');cli('--start-project',ident)
  until(lambda:(running(project) or {}).get('entryPoints'))
  url=next(x['value'] for x in menu(project) if x['title']=='打开网页')
  assert url.endswith('/hello%20%23.html'),url
  opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
  assert b'Chosen page' in opener.open(url,timeout=3).read()
  print('PASS: multi-page static target selection opens the exact percent-encoded HTML filename')
 finally:cli('--stop-project',ident,check=False)
 project=base/'External extension';project.mkdir()
 (project/'manifest.json').write_text(json.dumps({'manifest_version':3,'name':'External fixture','version':'1','background':{'service_worker':'worker.js'}}));(project/'worker.js').write_text('console.log("fixture")')
 cli('--add-project',str(project))
 browsers=sorted((Path.home()/'Library/Caches/ms-playwright').glob('chromium-*/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'))
 assert browsers,'Compatible test browser is missing'
 browser=subprocess.Popen([str(browsers[-1]),'--user-data-dir='+str(base/'browser-profile'),'--load-extension='+str(project),'--disable-extensions-except='+str(project),'--headless=new','--no-first-run','--remote-debugging-port=0','about:blank'],cwd=project,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 try:
  p=until(lambda:running(project))
  assert p['session']['canStop'] is False
  assert not any(x.get('action')=='stopProject:' for x in menu(project))
  assert cli('--stop-project',next(p['id'] for p in json.loads(cli('--list-projects').stdout) if p['path']==str(project)),check=False).returncode!=0
  assert browser.poll() is None
  print('PASS: externally loaded extension is discovered/openable; Stop cannot terminate an unmanaged browser')
 finally:
  if browser.poll() is None:os.killpg(browser.pid,signal.SIGTERM);browser.wait(timeout=10)
