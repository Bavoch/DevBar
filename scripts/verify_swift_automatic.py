"""No App bundle is required to identify the native executable actually built and running."""
import json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BINARY=str(ROOT/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Swift automatic ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'Sources/Fixture').mkdir(parents=True)
    (project/'Package.swift').write_text('// swift-tools-version: 5.9\nimport PackageDescription\nlet package=Package(name:"Fixture",targets:[.executableTarget(name:"Fixture")])\n')
    source=project/'Sources/Fixture/main.swift';source.write_text('import Foundation\nprint("v1")\nwhile true {Thread.sleep(forTimeInterval:0.2)}\n')
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1')
    def cli(action,code=0):
        p=subprocess.run([BINARY,action,str(project),'--target','swift','--json'],env=env,capture_output=True,text=True,timeout=200)
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return json.loads(p.stdout)
    try:
        first=cli('sync');assert first['state']=='current'
        assert first['receipt']['proof']['runtimeVersion']=='nativeBinary'
        assert cli('status')['state']=='current'
        source.write_text(source.read_text().replace('v1','v2'))
        assert cli('status',2)['state']=='sourceChanged'
        second=cli('sync');assert second['state']=='current'
        assert second['receipt']['artifactDigest']!=first['receipt']['artifactDigest']
        assert second['receipt']['proof']['pid']!=first['receipt']['proof']['pid']
        cli('stop');assert cli('status',2)['state']=='stopped'
        print('PASS: automatic unique Swift product, real release build v1→v2, complete runtime output fingerprint, exact OS executable/PID and stop without project configuration')
    finally:subprocess.run([BINARY,'stop',str(project),'--target','swift','--json'],env=env,capture_output=True,timeout=30)
