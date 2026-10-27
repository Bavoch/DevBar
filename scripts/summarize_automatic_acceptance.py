"""Keep actual project evidence separate from inferred recipes and current live state."""
import json
from pathlib import Path
from collections import Counter
ROOT=Path(__file__).resolve().parents[1];work=ROOT/'work';rows={}
files=['automatic-static-acceptance','automatic-frontend-acceptance','frontend-focused-acceptance','frontend-new-acceptance','frontend-additional-acceptance','automatic-extension-acceptance','automatic-ios-acceptance','automatic-host-acceptance','automatic-worker-acceptance','worker-focused-acceptance','automatic-graph-acceptance']
for filename in files:
 path=work/(filename+'.json')
 if not path.exists():continue
 report=json.loads(path.read_text())
 for row in report['results']:
  if row['project']==str(ROOT):continue # historical phantom Swift plan; self uses explicit desktop.
  key=(row['project'],row['target'])
  rows[key]={**row,'kind':report['kind'],'evidence':str(path.relative_to(ROOT))}
path=work/'jeju-group-acceptance.json'
if path.exists():
 report=json.loads(path.read_text())
 if report['state']=='current' and report['status']['state']=='current':
  for member in report['members']:
   plan=member['plan'];launch=plan['launch'];directory=launch['directory'];target=launch['id']
   relative=str(Path(directory).relative_to(plan['project']))
   if relative!='.':target=target.removeprefix(relative+':')
   mode=plan['configuration'].get('runtimeWitness')
   kind='worker' if mode=='workerHTTP' else 'frontend' if launch['kind']=='web' else 'job'
   rows[directory,target]={'project':directory,'target':target,'state':'current','kind':kind,'evidence':str(path.relative_to(ROOT)),'context':'complete group, isolated SQLite-backed snapshot of local Worker state','proof':member.get('receipt',{}).get('proof')}
path=work/'spaceshelf-runtime-acceptance.json'
if path.exists():
 report=json.loads(path.read_text());plan=report['plan']
 rows[plan['project'],plan['target']]={'project':plan['project'],'target':plan['target'],'state':report['state'],'kind':'desktop','evidence':str(path.relative_to(ROOT))}
report={'evidence':'actualRuntimeAcceptanceAtTestTime; owned test sessions stopped afterwards; not a claim that every project is currently running or UI workflows accepted','counts':dict(Counter(r['state'] for r in rows.values())),'acceptedByKind':dict(Counter(r['kind'] for r in rows.values() if r['state']=='current')),'results':sorted(rows.values(),key=lambda r:(r['project'],r['target']))}
(work/'automatic-runtime-summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ['counts','acceptedByKind']},ensure_ascii=False))
