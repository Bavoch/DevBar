"""Read-only product coverage report; source, environment and runtime evidence stay separate."""
from pathlib import Path
import argparse,collections,json,os,subprocess
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--directory',default=str(Path.home()/'Coding'))
parser.add_argument('--output',required=True)
args=parser.parse_args()
binary=os.environ.get('DEVBAR_TEST_BINARY',str(root/'.build/release/DevBar'))
result=subprocess.run([binary,'inventory',args.directory,'--json'],capture_output=True,text=True,timeout=180)
if result.returncode not in (0,2): raise RuntimeError(result.stdout or result.stderr)
report=json.loads(result.stdout)
projects=report['projects']
summary={'topLevelDirectories':report['topLevelDirectories'],'auditedRoots':report['projectRoots'],
         'readinessState':report['state'],
         'launchTargets':sum(len(p['profile']['targets']) for p in projects),
         'projectErrors':sum(i['severity']=='error' for p in projects for i in p['issues']),
         'targetsWithoutStrictSync':sum(i['code']=='syncNotConfigured' for p in projects for c in p['capabilities'] for i in c['issues']),
         'withTargets':sum(bool(p['profile']['targets']) for p in projects),
         'byRole':dict(collections.Counter(p['role'] for p in projects)),
         'byKind':dict(collections.Counter(t['kind'] for p in projects for t in p['profile']['targets'])),
         'blockedTargets':sum(c['launch']=='blocked' for p in projects for c in p['capabilities']),
         'automaticTargets':sum(len(p.get('automaticSyncTargets',[])) for p in projects),
         'configuredProjects':sum(bool(p['configuredSyncTargets']) for p in projects),
         'inventoryIssues':len(report['issues']),
         'runtimeAcceptance':'Only isolated adapter E2E fixtures and explicitly tested real projects; this inventory does not execute projects.'}
report['summary']=summary
out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
lines=['# DevBar 项目覆盖审查','',f"目录：{report['directory']}；{summary['topLevelDirectories']} 个顶层目录，{summary['auditedRoots']} 个项目位置。",'',
       '全部记录为只读配置和环境审查，不代表所有真实应用已运行、已更新或已完成功能验收。库、宿主插件、容器、备份和空目录分别分类。', '',
       f"只读检查状态：{summary['readinessState']}；{summary['launchTargets']} 个运行目标，{summary['blockedTargets']} 个启动阻碍，{summary['projectErrors']} 个项目配置错误。", '',
       f"严格更新接入：{summary['automaticTargets']} 个自动目标，{summary['configuredProjects']} 个工程有显式配置；{summary['targetsWithoutStrictSync']} 个运行目标仍无严格映射。自动计划与工具检查不代表已完成实际运行核对。", '',
       '运行版本证据使用各平台适配器。process 必须有运行版本探针；设备或宿主必须返回自身版本证据。', '',
       '| 项目位置 | 角色 | 运行目标 | 阻碍与接入要求 |', '|---|---|---|---|']
base=Path(report['directory'])
for p in projects:
    targets='；'.join(t['id']+' ('+t['kind']+')' for t in p['profile']['targets']) or '无独立运行入口'
    issues=p['issues']+[i for c in p['capabilities'] for i in c['issues']]
    notes='；'.join(dict.fromkeys(i['message'] for i in issues)) or '配置与环境未发现阻碍'
    vals=[str(Path(p['path']).relative_to(base)),p['role'],targets,notes]
    lines.append('| '+' | '.join(v.replace('|','/').replace('\n',' ') for v in vals)+' |')
for issue in report['issues']: lines+=['',issue['code']+'：'+issue['message']]
out.with_suffix('.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(summary,ensure_ascii=False))
