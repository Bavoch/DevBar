"""Validate every inferred recipe without running scripts or changing project files."""
import json, os, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=ROOT/'work/2026-10-23-automatic-audit.json'
projects=json.loads(source.read_text())['projects'];results=[]
for project in projects:
    if project['role']=='archive':continue
    for target in project['automaticSyncTargets']:
        p=subprocess.run([str(ROOT/'.build/release/DevBar'),'sync',project['path'],'--target',target,'--plan','--json'],capture_output=True,text=True,timeout=60)
        value=json.loads(p.stdout)
        results.append({'project':project['path'],'target':target,'state':value['state'],'reason':value.get('reason'),'strategy':value.get('plan',{}).get('strategy')})
report={'evidence':'readOnlyPlans; not runtime acceptance','results':results,'counts':{state:sum(r['state']==state for r in results) for state in {r['state'] for r in results}}}
(ROOT/'work/automatic-plan-acceptance.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report['counts']))
for r in results:
    if r['state']!='planned':print(json.dumps(r,ensure_ascii=False))
