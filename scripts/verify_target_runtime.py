"""Actual isolated browser extension and iOS simulator lifecycle, without foreground browser windows."""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,tempfile,time,urllib.request,signal
root=Path(__file__).resolve().parents[1];binary=os.environ.get('DEVBAR_TEST_BINARY',str(root/'.build/release/DevBar'))
parser=argparse.ArgumentParser();parser.add_argument('kind',choices=['extension','ios']);args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='Target runtime ',dir=root/'work') as folder:
 base=Path(folder);project=base/'Project with spaces';project.mkdir();state=base/'state';env=dict(os.environ,DEVBAR_DATA_DIR=str(state),DEVBAR_HEADLESS='1')
 def cli(*args,check=True,timeout=45):
  return subprocess.run([binary,*args],env=env,capture_output=True,text=True,check=check,timeout=timeout)
 def find():
  return next((p for p in json.loads(cli('--scan-json').stdout) if p['path']==str(project)),None)
 ident=None;bundle=None;device=None
 try:
  if args.kind=='extension':
   (project/'manifest.json').write_text(json.dumps({'manifest_version':3,'name':'DevBar runtime fixture','version':'1.0','background':{'service_worker':'worker.js'},'action':{'default_popup':'popup.html'}}))
   (project/'worker.js').write_text('chrome.runtime.onInstalled.addListener(() => console.log("DevBar fixture installed"));')
   (project/'popup.html').write_text('<!doctype html><title>DevBar fixture</title><h1>Extension fixture</h1>')
  else:
   bundle='local.devbar.fixture.'+str(os.getpid())
   (project/'project.yml').write_text(json.dumps({'name':'RuntimeFixture','targets':{'RuntimeFixture':{'type':'application','platform':'iOS','deploymentTarget':'17.0','sources':['Sources'],'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':bundle,'GENERATE_INFOPLIST_FILE':True,'SWIFT_VERSION':'5.0','CODE_SIGNING_ALLOWED':'NO','INFOPLIST_KEY_UILaunchScreen_Generation':True,'TARGETED_DEVICE_FAMILY':'1,2'}}}}}))
   (project/'Sources').mkdir()
   (project/'Sources/App.swift').write_text('''import UIKit
@main final class App: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  let window = UIWindow(frame: UIScreen.main.bounds)
  let view = UIViewController();view.view.backgroundColor = .systemBackground
  let label = UILabel(frame: CGRect(x: 30, y: 200, width: 320, height: 80));label.text = "DevBar runtime verified";label.textColor = .label
  view.view.addSubview(label);window.rootViewController = view;window.makeKeyAndVisible();self.window = window;return true
 }
}
''')
  ident=cli('--add-project',str(project)).stdout.strip()
  cli('--start-project',ident)
  deadline=time.monotonic()+240
  session=None
  while time.monotonic()<deadline:
   files=list((state/'targets').glob('*.json'))
   if files:
    session=json.loads(files[0].read_text());break
   logs=list(state.glob('*.log'))
   if logs and '开发命令已退出' in logs[0].read_text(errors='replace'):
    raise AssertionError(logs[0].read_text(errors='replace')[-2500:])
   time.sleep(.5)
  assert session, 'Target session was not established; '+next(state.glob('*.log')).read_text(errors='replace')[-3500:]
  device=session.get('device')
  running=find();assert running and running.get('session'),running
  assert running['session']['pid']==session['pid'] and running['session']['kind']==('browserExtension' if args.kind=='extension' else 'ios')
  menu=next(p for p in json.loads(cli('--menu-json').stdout) if p.get('title')==project.name)
  expected='打开插件' if args.kind=='extension' else '打开模拟器'
  assert any(p['title']==expected and p.get('action')=='openTargetSession:' for p in menu['items'])
  if args.kind=='extension':
   key=hashlib.sha256(str(project).encode()).hexdigest();active=state/'browsers'/key/'DevToolsActivePort'
   deadline=time.monotonic()+20;targets=[]
   while time.monotonic()<deadline:
    if active.exists():
     port=int(active.read_text().splitlines()[0])
     try:
      targets=json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(f'http://127.0.0.1:{port}/json/list',timeout=1))
      if any(t.get('type')=='service_worker' and t.get('url','').startswith('chrome-extension://') for t in targets):break
     except Exception:pass
    time.sleep(.25)
   assert any(t.get('type')=='service_worker' and t.get('url','').endswith('/worker.js') for t in targets),targets
   assert not running['entryPoints'], 'Browser debugger must not become a project webpage'
   print('PASS: real MV3 service worker loaded in isolated headless Chromium, exact session tracked, dedicated Open action, debugger excluded')
   (project/'popup.html').write_text('<!doctype html><h1>Extension source v2</h1>')
   previous=session['pid'];deadline=time.monotonic()+35
   while time.monotonic()<deadline:
    try:
     candidate=json.loads(next((state/'targets').glob('*.json')).read_text())
     if candidate['pid']!=previous:
      session=candidate;break
    except (FileNotFoundError,StopIteration,json.JSONDecodeError):pass
    time.sleep(.25)
   assert session['pid']!=previous, 'Extension source edit did not reload browser session'
   print('PASS: extension source edit automatically replaces the isolated development browser session')
  else:
   installed=subprocess.check_output(['xcrun','simctl','listapps',device],text=True)
   assert bundle in installed
   subprocess.run(['xcrun','simctl','io',device,'screenshot',str(root/'work/ios-runtime.png')],check=True,capture_output=True)
   (root/'work/ios-session-diagnostic.json').write_text(json.dumps(session))
   saved_sessions = [(file, file.read_bytes()) for file in (state/'targets').glob('*.json')]
   for file, _ in saved_sessions:file.unlink()
   external=find()
   assert external and external.get('session',{}).get('pid')==session['pid'] and external['session']['targetID']=='external:ios', {'fixtureExecutable': session['executable'], 'external': external}
   for file, data in saved_sessions:file.write_bytes(data)
   print('PASS: external simulator App is rediscovered from its exact bundle identity without DevBar runtime history')
   print('PASS: generated iOS fixture built, installed and launched on simulator; exact PID/bundle/device tracked; Open targets simulator')
  cli('--stop-project',ident)
  assert find() is None
  previous_session_pid=session['pid']
  assert cli('--start-project',ident,check=False).returncode==0, 'Stopped target must start again'
  deadline=time.monotonic()+150
  while time.monotonic()<deadline:
   try:
    next_session=json.loads(next((state/'targets').glob('*.json')).read_text())
    if next_session['pid']!=session['pid']:
     session=next_session;break
   except Exception:pass
   time.sleep(.5)
  assert session['pid']!=previous_session_pid
  cli('--stop-project',ident)
  print('PASS: stop removes target runtime and repeat launch produces a new verified session')
 finally:
  if ident:
   cli('--stop-project',ident,check=False)
  if bundle and device:
   subprocess.run(['xcrun','simctl','terminate',device,bundle],capture_output=True)
   subprocess.run(['xcrun','simctl','uninstall',device,bundle],capture_output=True)
