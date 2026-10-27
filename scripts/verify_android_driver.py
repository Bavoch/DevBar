"""Real adb APK build/install/update/proof test. Emulator evidence is explicitly labelled."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
SDK=Path(os.environ.get('ANDROID_HOME',str(Path.home()/'Library/Android/sdk')))
ADB=str(SDK/'platform-tools/adb');serial=os.environ.get('DEVBAR_ANDROID_TEST_DEVICE','emulator-5554')
def adb(*args): return subprocess.check_output([ADB,'-s',serial,*args],text=True,timeout=20).strip()
for _ in range(160):
 try:
  if adb('shell','getprop','sys.boot_completed')=='1':break
 except (subprocess.CalledProcessError,subprocess.TimeoutExpired):pass
 time.sleep(.5)
else:raise RuntimeError('Android runtime did not boot')
with tempfile.TemporaryDirectory(prefix='Android sync ',dir=ROOT/'work') as directory:
 root=Path(directory);(root/'work').mkdir();(root/'src').mkdir()
 package='local.devbar.fixture.p'+str(os.getpid())
 (root/'src/DevBarRuntime.java').write_text((ROOT/'drivers/sdk/DevBarRuntime.java').read_text())
 (root/'src/MainActivity.java').write_text('''package PACKAGE;
import android.app.Activity;import android.os.Bundle;import android.widget.TextView;import local.devbar.runtime.DevBarRuntime;
public class MainActivity extends Activity {public void onCreate(Bundle saved){super.onCreate(saved);TextView v=new TextView(this);v.setText("REVISION");setContentView(v);try{DevBarRuntime.record(this,getIntent());}catch(Exception e){throw new RuntimeException(e);}}}
'''.replace('PACKAGE',package).replace('REVISION','v1'))
 (root/'AndroidManifest.xml').write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" android:versionCode="1" android:versionName="1"><uses-sdk android:minSdkVersion="26" android:targetSdkVersion="35"/><application android:debuggable="true" android:label="DevBar Fixture" android:theme="@android:style/Theme.Material.Light.NoActionBar"><activity android:name=".MainActivity" android:exported="true"><intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter></activity></application></manifest>''')
 build='''import pathlib,subprocess,os,json,zipfile,shutil
r=pathlib.Path(__file__).parent;w=r/'work';sdk=pathlib.Path(os.environ['ANDROID_HOME']);tools=sdk/'build-tools/35.0.0';jdk=pathlib.Path(os.environ['JAVA_HOME'])/'bin';jar=sdk/'platforms/android-35/android.jar'
def run(args):subprocess.run([str(a) for a in args],check=True)
assets=w/'assets';assets.mkdir(exist_ok=True);(assets/'devbar-build.json').write_text(json.dumps({'sourceDigest':os.environ['DEVBAR_SOURCE_DIGEST']}))
classes=w/'classes';shutil.rmtree(classes,ignore_errors=True);classes.mkdir()
run([jdk/'javac','--release','8','-cp',jar,'-d',classes,*sorted((r/'src').glob('*.java'))])
run([tools/'d8','--lib',jar,'--min-api','26','--output',w/'dex.zip',*sorted(classes.rglob('*.class'))])
run([tools/'aapt','package','-f','-M',r/'AndroidManifest.xml','-I',jar,'-A',assets,'-F',w/'unsigned.apk'])
with zipfile.ZipFile(w/'dex.zip') as z,zipfile.ZipFile(w/'unsigned.apk','a') as out:out.writestr('classes.dex',z.read('classes.dex'))
run([tools/'zipalign','-f','4',w/'unsigned.apk',w/'aligned.apk'])
key=w/'debug.keystore'
if not key.exists():run([jdk/'keytool','-genkeypair','-keystore',key,'-storepass','android','-keypass','android','-alias','devbar','-keyalg','RSA','-validity','30','-dname','CN=DevBar E2E Fixture'])
run([tools/'apksigner','sign','--ks',key,'--ks-pass','pass:android','--key-pass','pass:android','--out',w/'app.apk',w/'aligned.apk'])
'''
 (root/'build.py').write_text(build)
 cfg={'schemaVersion':1,'targets':{'android':{'strategy':'androidDevice','buildCommand':'python3 build.py','artifact':'work/app.apk','device':serial,'bundleIdentifier':package,'activity':'.MainActivity','timeout':180}}}
 (root/'.devbar.json').write_text(json.dumps(cfg));env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'work/state'),ANDROID_HOME=str(SDK),JAVA_HOME='/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
 def cli(action,expected=0):
  p=subprocess.run([BINARY,action,str(root),'--target','android','--json'],capture_output=True,text=True,env=env,timeout=240)
  assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
  return json.loads(p.stdout)
 try:
  v1=cli('sync');assert v1['state']=='current'
  one=v1['receipt']['proof'];assert cli('status')['state']=='current'
  adb('shell','run-as',package,'touch','files/preserved-user-data')
  entry=root/'src/MainActivity.java';entry.write_text(entry.read_text().replace('v1','v2'))
  assert cli('status',2)['state']=='sourceChanged'
  v2=cli('sync');two=v2['receipt']['proof'];assert one['instanceID']!=two['instanceID']
  assert one['sourceDigest']!=two['sourceDigest']
  adb('shell','run-as',package,'ls','files/preserved-user-data')
  assert cli('sync')['receipt']['syncID']==v2['receipt']['syncID']
  cli('stop');assert cli('status',2)['state']=='unconfirmed'
  evidence={'passed':True,'device':serial,'deviceKind':'emulator' if adb('shell','getprop','ro.kernel.qemu')=='1' else 'physical','v1':one,'v2':two,'preservedUserData':True}
  (ROOT/'work/android-driver-evidence.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
 finally:
  subprocess.run([ADB,'-s',serial,'uninstall',package],capture_output=True,timeout=30)
