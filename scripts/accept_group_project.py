"""Actual grouped application acceptance, isolated state, exact owned-member cleanup."""
import argparse,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('project');p.add_argument('--target',default='dev');p.add_argument('--output',required=True);p.add_argument('--snapshot-worker-state',action='store_true');args=p.parse_args()
with tempfile.TemporaryDirectory(prefix='Group project ',dir=ROOT/'work') as folder:
 env=dict(os.environ,DEVBAR_DATA_DIR=folder,DEVBAR_HEADLESS='1',BROWSER='none',WRANGLER_SEND_METRICS='false')
 def cli(action,*flags):
  result=subprocess.run([str(ROOT/'.build/release/DevBar'),action,args.project,'--target',args.target,'--json',*flags],env=env,capture_output=True,text=True,timeout=1000)
  return json.loads(result.stdout)
 try:
  snapshots=[]
  if args.snapshot_worker_state:
   import hashlib,shutil,sqlite3
   def collect(report):
    plan=report.get('plan',{});config=plan.get('configuration',{})
    if config.get('runtimeWitness')=='workerHTTP':
     directory=Path(plan['launch']['directory'])
     for directory in [directory,*list(directory.parents)[:3]]:
      if any((directory/name).is_file() for name in ['wrangler.toml','wrangler.json','wrangler.jsonc']):break
     source=directory/'.wrangler/state'
     if source.is_dir():
      destination=Path(folder)/'worker-data'/hashlib.sha256((plan['project']+'\n'+plan['target']).encode()).hexdigest()
      def clone(a,b):
       result=subprocess.run(['/bin/cp','-c',str(a),str(b)],capture_output=True)
       if result.returncode:shutil.copy2(a,b)
       return b
      for link in source.rglob('*'):
       if link.is_symlink() and not link.resolve().is_relative_to(source.resolve()):raise RuntimeError('Worker data snapshot would cross its source directory')
      shutil.copytree(source,destination,copy_function=clone)
      for database in source.rglob('*.sqlite'):
       target=destination/database.relative_to(source)
       for suffix in ['-wal','-shm']:Path(str(target)+suffix).unlink(missing_ok=True)
       with sqlite3.connect(database.resolve().as_uri()+'?mode=ro',uri=True,timeout=5) as original,sqlite3.connect(target) as snapshot:original.backup(snapshot)
      snapshots.append(str(source))
    for member in report.get('members',[]):collect(member)
   collect(cli('sync','--plan'))
  report=cli('sync')
  report['localDataSnapshots']=snapshots
  if report['state']=='current':
   report['status']=cli('status')
   assert report['status']['state']=='current',report['status']
  for index,member in enumerate(report.get('members',[])):
   value=member.get('report',member)
   if value.get('log'):
    import shutil
    log=Path(args.output).with_suffix('.'+str(index)+'.log');shutil.copyfile(value['log'],log);value['log']=str(log)
  Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
  print(json.dumps({'project':args.project,'state':report['state'],'reason':report.get('reason')},ensure_ascii=False))
 finally:cli('stop')
