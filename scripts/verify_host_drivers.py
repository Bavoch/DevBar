"""Actual Blender and OMP processes: loading, updating, stale proof rejection, exact stop."""
from pathlib import Path
import json,os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
results=[]
for strategy,entry,body in [('blender','entry.py','import bpy\nbpy.context.scene["devbar_revision"] = "REVISION"\n'),('omp','entry.ts','export default function(api){ api.on("session_start",()=>{}); } // REVISION\n')]:
 with tempfile.TemporaryDirectory(prefix='DevBar '+strategy+' ',dir=ROOT/'work') as directory:
  root=Path(directory);(root/'work').mkdir();env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'work/state'))
  config={'schemaVersion':1,'targets':{'host':{'strategy':strategy,'entry':entry,'timeout':90}}}
  (root/'.devbar.json').write_text(json.dumps(config));(root/entry).write_text(body.replace('REVISION','v1'))
  def cli(action,code=0):
   p=subprocess.run([BINARY,action,str(root),'--target','host','--json'],env=env,capture_output=True,text=True,timeout=210)
   assert p.returncode==code,(strategy,p.returncode,p.stdout,p.stderr)
   return json.loads(p.stdout)
  try:
   v1=cli('sync');assert v1['state']=='current',v1
   one=v1['receipt']['proof'];assert cli('status')['receipt']['proof']==one
   (root/entry).write_text(body.replace('REVISION','v2'))
   assert cli('status',2)['state']=='sourceChanged'
   v2=cli('sync');two=v2['receipt']['proof'];assert one['instanceID']!=two['instanceID']
   assert one['sourceDigest']!=two['sourceDigest']
   assert cli('sync')['receipt']['syncID']==v2['receipt']['syncID']
   cli('stop');assert cli('status',2)['state']=='unconfirmed'
   results.append({'driver':strategy,'passed':True,'v1':one,'v2':two})
  finally:
   try:cli('stop')
   except Exception:pass
(ROOT/'work/host-driver-evidence.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
