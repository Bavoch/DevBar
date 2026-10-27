"""The updater CLI inside the target .app must not try to terminate itself."""
from pathlib import Path
import json,os,plistlib,shutil,signal,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];APP=Path(os.environ.get('DEVBAR_TEST_APP',str(ROOT/'dist/DevBar.app')))
BINARY=APP/'Contents/MacOS/DevBar'
with tempfile.TemporaryDirectory(prefix='Embedded self updater ',dir=ROOT/'work') as directory:
 root=Path(directory);work=root/'work';work.mkdir();installed=work/'Installed.app'
 shutil.copytree(APP,installed)
 identifier='local.devbar.self.fixture.'+str(os.getpid())
 info=plistlib.loads((installed/'Contents/Info.plist').read_bytes());info['CFBundleIdentifier']=identifier
 (installed/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
 subprocess.run(['codesign','--force','--sign','-',str(installed)],check=True,capture_output=True)
 native=work/'Fixture.m';native.write_text('''#import <AppKit/AppKit.h>
int main(){@autoreleasepool{NSApplication *a=[NSApplication sharedApplication];[a setActivationPolicy:NSApplicationActivationPolicyProhibited];[a run];}return 0;}
''')
 subprocess.run(['clang','-framework','AppKit','-x','objective-c',str(native),'-o',str(work/'Fixture')],check=True,capture_output=True)
 (work/'info.plist').write_bytes(plistlib.dumps(info));(root/'source.txt').write_text('new embedded updater')
 (root/'build.py').write_text('''import pathlib,shutil,subprocess
r=pathlib.Path(__file__).parent;a=r/'dist/Fixture.app'
(a/'Contents/MacOS').mkdir(parents=True);(a/'Contents/Resources').mkdir()
shutil.copy2(r/'work/Fixture',a/'Contents/MacOS/DevBar');shutil.copy2(r/'work/info.plist',a/'Contents/Info.plist')
(a/'Contents/Resources/revision.txt').write_text((r/'source.txt').read_text())
subprocess.run(['codesign','--force','--sign','-',str(a)],check=True,capture_output=True)
''')
 (root/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'desktop':{'strategy':'macBundle','buildCommand':'python3 build.py','artifact':'dist/Fixture.app','installPath':str(installed),'bundleIdentifier':identifier,'sourcePaths':['source.txt','build.py','.devbar.json'],'timeout':60}}}))
 env=dict(os.environ,DEVBAR_DATA_DIR=str(work/'state'));pid=None
 try:
  result=subprocess.run([str(installed/'Contents/MacOS/DevBar'),'sync',str(root),'--target','desktop','--json'],env=env,capture_output=True,text=True,timeout=100)
  assert result.returncode==0,(result.stdout,result.stderr)
  value=json.loads(result.stdout);assert value['state']=='current';pid=value['receipt']['pid']
  status=subprocess.run([str(BINARY),'status',str(root),'--target','desktop','--json'],env=env,capture_output=True,text=True,timeout=30)
  assert status.returncode==0 and json.loads(status.stdout)['state']=='current',(status.stdout,status.stderr)
  (ROOT/'work/embedded-self-sync-evidence.json').write_text(json.dumps({'passed':True,'pid':pid,'state':'current','embeddedCLIUpdatedOwnBundle':True},indent=2))
  print('PASS: installed bundle CLI updates its own bundle, does not terminate itself, and read-only status verifies new native process')
 finally:
  if pid:
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
