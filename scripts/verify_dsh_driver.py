"""Real official DSH + headless Chromium: actual plugin apply, update, status, stop."""
from pathlib import Path
import json,os,subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
HOST=os.environ.get('DEVBAR_DSH_HOST')
if not HOST or not Path(HOST).expanduser().is_file():
 raise SystemExit('Set DEVBAR_DSH_HOST to the installed official DSH entry; use a dedicated test host')
HOST=str(Path(HOST).expanduser().resolve())
with tempfile.TemporaryDirectory(prefix='DSH driver ',dir=ROOT/'work') as directory:
 root=Path(directory);(root/'work').mkdir()
 (root/'package.json').write_text(json.dumps({'name':'@devbar/e2e-plugin','version':'1.0.0','type':'module','exports':{'.':'./index.js','./client':'./client.js'},'dsh':{'bundle':{'patch':'./cordis.patch.yml'},'client':{'platform':'web','immediately':True,'inject':[]}}}))
 (root/'index.js').write_text('export function apply(ctx) {}\n')
 (root/'cordis.patch.yml').write_text('- insert:\n    - id: devbar-e2e\n      name: "@devbar/e2e-plugin"\n      config: {}\n')
 client=root/'client.js'
 body='window.__ModuleLoader__.load({id:"@devbar/e2e-plugin",factory(){return {apply(){window.devbarFixture="REVISION"}}}});\n'
 client.write_text(body.replace('REVISION','v1'))
 (root/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'dsh':{'strategy':'dsh','entry':'index.js','hostExecutable':HOST,'timeout':120}}}))
 env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'work/state'))
 def cli(action,expected=0):
  p=subprocess.run([BINARY,action,str(root),'--target','dsh','--json'],capture_output=True,text=True,env=env,timeout=210)
  if p.returncode!=expected:
   logs=ROOT/'work/dsh-failure-logs';logs.mkdir(exist_ok=True)
   for source in (root/'work/state/sync').rglob('*.log'):
    shutil.copy2(source,logs/source.name)
  assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
  return json.loads(p.stdout)
 try:
  first=cli('sync');assert first['state']=='current'
  one=first['receipt']['proof'];assert cli('status')['state']=='current'
  client.write_text(body.replace('REVISION','v2'));assert cli('status',2)['state']=='sourceChanged'
  second=cli('sync');two=second['receipt']['proof'];assert one['instanceID']!=two['instanceID'] and one['sourceDigest']!=two['sourceDigest']
  assert cli('sync')['receipt']['syncID']==second['receipt']['syncID']
  cli('stop');assert cli('status',2)['state']=='unconfirmed'
  evidence={'driver':'dsh','passed':True,'browser':'headless','v1':one,'v2':two}
  (ROOT/'work/dsh-driver-evidence.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
 finally:
  try:cli('stop')
  except Exception:pass
