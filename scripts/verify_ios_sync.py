"""Actual simulator compilation/install/update and application-written runtime observation."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='iOS sync ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'Sources').mkdir();(project/'work').mkdir()
    bundle='local.devbar.sync.ios.'+str(os.getpid())
    (project/'project.yml').write_text(json.dumps({'name':'RuntimeSync','targets':{'RuntimeSync':{'type':'application','platform':'iOS','deploymentTarget':'17.0','sources':['Sources'],'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':bundle,'GENERATE_INFOPLIST_FILE':True,'SWIFT_VERSION':'5.0','CODE_SIGNING_ALLOWED':'NO','INFOPLIST_KEY_UILaunchScreen_Generation':True,'TARGETED_DEVICE_FAMILY':'1,2'}}}}}))
    code='''import UIKit
@main final class App: UIResponder, UIApplicationDelegate {
 var window: UIWindow?
 func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
  let window=UIWindow(frame: UIScreen.main.bounds);let view=UIViewController();view.view.backgroundColor = .systemBackground
  let label=UILabel(frame:CGRect(x:30,y:180,width:320,height:80));label.text="REVISION";view.view.addSubview(label)
  window.rootViewController=view;window.makeKeyAndVisible();self.window=window
  let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
  try? FileManager.default.createDirectory(at:documents,withIntermediateDirectories:true)
  let value:[String:Any] = ["revision":"REVISION","pid":Int(getpid())]
  try? JSONSerialization.data(withJSONObject:value).write(to:documents.appendingPathComponent("observed.json"),options:.atomic)
  return true
 }
}
'''
    source=project/'Sources/App.swift';source.write_text(code.replace('REVISION','v1'))
    (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'ios':{'strategy':'iosSimulator','launchTarget':'simulator:RuntimeSync.xcodeproj','sourcePaths':['Sources','project.yml','.devbar.json'],'timeout':240}}}))
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1')
    def cli(action,expected=0):
        r=subprocess.run([BINARY,action,str(project),'--json'],env=env,capture_output=True,text=True,timeout=300)
        if r.returncode!=expected:
            value=json.loads(r.stdout)
            if value.get('log'):
                import shutil
                shutil.copyfile(value['log'],ROOT/'work/automatic-ios-failure.log')
        assert r.returncode==expected,(r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout)
    device=None
    try:
        first=cli('sync');assert first['state']=='current'
        device=first['receipt']['session']['device']
        data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'data'],text=True).strip())
        assert json.loads((data/'Documents/observed.json').read_text())=={'revision':'v1','pid':first['receipt']['session']['pid']}
        (data/'Documents/persisted-user-data.txt').write_text('must survive update')
        assert cli('status')['state']=='current'
        assert cli('sync')['receipt']['session']['pid']==first['receipt']['session']['pid']
        installed=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'app'],text=True).strip())
        (installed/'ObsoleteProduct.debug.dylib').write_text('stale renamed product')
        source.write_text(code.replace('REVISION','v2'))
        assert cli('status',2)['state']=='sourceChanged'
        second=cli('sync');assert second['state']=='current'
        assert second['receipt']['session']['pid']!=first['receipt']['session']['pid']
        assert second['receipt']['artifactDigest']!=first['receipt']['artifactDigest']
        data=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'data'],text=True).strip())
        assert json.loads((data/'Documents/observed.json').read_text())=={'revision':'v2','pid':second['receipt']['session']['pid']}
        assert (data/'Documents/persisted-user-data.txt').read_text()=='must survive update'
        installed=Path(subprocess.check_output(['xcrun','simctl','get_app_container',device,bundle,'app'],text=True).strip())
        assert not (installed/'ObsoleteProduct.debug.dylib').exists()
        assert cli('status')['state']=='current'
        cli('stop');assert cli('status',2)['state']=='stopped'
        print('PASS: real iOS simulator v1→v2 compile/install/launch, source/built/installed App equality, application-written runtime version and PID, idempotence and exact simulator stop; no foreground simulator window')
    finally:
        subprocess.run([BINARY,'stop',str(project),'--json'],env=env,capture_output=True,timeout=25)
        if device:
            subprocess.run(['xcrun','simctl','terminate',device,bundle],capture_output=True)
            subprocess.run(['xcrun','simctl','uninstall',device,bundle],capture_output=True)
