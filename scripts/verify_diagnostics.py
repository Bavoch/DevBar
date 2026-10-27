"""Product inventory, target boundaries and configuration failures are read-only."""
from pathlib import Path
import json,os,plistlib,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='Product diagnostics ',dir=ROOT/'work') as folder:
    base=Path(folder);env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'))
    def write(project,name,value):
        p=project/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value) if isinstance(value,dict) else value)
    def cli(action,path,*args,code=0):
        r=subprocess.run([BINARY,action,str(path),*args,'--json'],env=env,capture_output=True,text=True,timeout=30)
        assert (r.returncode==code if code is not None else r.returncode in (0,2)),(r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout)
    project=base/'Native wrapper'
    write(project,'package.json',{'scripts':{'dev':'swift run'}})
    write(project,'Package.swift','let package=Package(targets:[.executableTarget(name:"Example")])')
    write(project,'Sources/main.swift','import SwiftUI\n')
    write(project,'scripts/watch.sh','echo MUST_NOT_RUN; exit 1\n')
    profile=cli('doctor',project)['profile']
    assert profile['targets'][0]['kind']=='desktop' and profile['targets'][0]['command']=='zsh scripts/watch.sh'
    write(project,'scripts/build.sh','touch MUST_NOT_RUN\n')
    app=project/'build/Example.app/Contents';(app/'MacOS').mkdir(parents=True)
    (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.devbar.draft','CFBundleExecutable':'Example'}))
    (app/'MacOS/Example').write_text('#!/bin/sh\nexit 0\n');(app/'MacOS/Example').chmod(0o755)
    draft=cli('init',project,'--target','swift','--plan')
    assert draft['configuration']['targets']['swift']['strategy']=='macBundle'
    assert cli('sync',project,'--target','swift','--plan')['state']=='planned'
    assert not (project/'MUST_NOT_RUN').exists() and not (project/'.devbar.json').exists()
    workspace=base/'Workspace'
    write(workspace,'package.json',{'workspaces':['apps/*','!apps/skip']})
    for name in ['keep','skip']:write(workspace,f'apps/{name}/package.json',{'scripts':{'dev':'python3 -m http.server 0 --bind 127.0.0.1'}})
    ids=[t['id'] for t in cli('doctor',workspace)['profile']['targets']]
    assert 'apps/keep:dev' in ids and 'apps/skip:dev' not in ids
    docs=base/'Docs';write(docs,'package.json',{'scripts':{'docs:dev':'vitepress dev docs'}})
    assert cli('doctor',docs,code=None)['profile']['targets'][0]['kind']=='web'
    plugin=base/'Plugin';write(plugin,'package.json',{'dsh':{'bundle':{'patch':'./patch.yml'}},'exports':{'.':'./index.js'}})
    assert cli('doctor',plugin)['role']=='hostPlugin' and not cli('doctor',plugin)['profile']['targets']
    container=base/'Container';write(container,'Dockerfile','FROM scratch\n')
    assert cli('doctor',container)['role']=='container'
    (base/'Empty').mkdir()
    write(base/'Ignored/node_modules/Fake','package.json',{'scripts':{'dev':'touch MUST_NOT_RUN'}})
    result=cli('inventory',base,code=2)
    assert result['state']=='unconfirmed', result['state']
    assert not result['issues']
    assert not any('/node_modules/Fake' in p['path'] for p in result['projects'])
    assert any(p['role']=='empty' for p in result['projects'])
    write(project,'.devbar.json',{'schemaVersion':1,'targets':{'broken':{'strategy':'macBundle','buildComand':'touch MUST_NOT_RUN','artifact':'build/Example.app'}}})
    assert cli('sync',project,'--plan',code=1)['state']=='setupRequired'
    assert not (project/'MUST_NOT_RUN').exists()
    print('PASS: native Swift wrapper/watch detection, safe macBundle draft, workspace exclusions, VitePress, host plugin/container/empty classification, complete bounded read-only inventory and strict invalid configuration rejection')
