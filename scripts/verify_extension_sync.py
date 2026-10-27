"""Build/reload real MV3 content twice in a dedicated headless Chromium session."""
from pathlib import Path
import json,os,subprocess,tempfile,time
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='Extension sync ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'work').mkdir()
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),DEVBAR_HEADLESS='1')
    (project/'manifest.json').write_text(json.dumps({'manifest_version':3,'name':'DevBar sync fixture','version':'1.0','background':{'service_worker':'worker.js'}}))
    (project/'worker.js').write_text('globalThis.revision="v1";')
    (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'extension':{'strategy':'extension','launchTarget':'extension','timeout':30}}}))
    def cli(action,code=0):
        r=subprocess.run([BINARY,action,str(project),'--json'],env=env,capture_output=True,text=True,timeout=50)
        assert r.returncode==code,(r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout)
    try:
        first=cli('sync');assert first['state']=='current'
        pid=first['receipt']['session']['pid'];assert first['receipt']['artifactDigest']
        assert cli('status')['state']=='current'
        assert cli('sync')['receipt']['session']['pid']==pid
        (project/'worker.js').write_text('globalThis.revision="v2";')
        assert cli('status',2)['state']=='sourceChanged'
        second=cli('sync');assert second['receipt']['session']['pid']!=pid
        assert second['receipt']['artifactDigest']!=first['receipt']['artifactDigest']
        assert cli('status')['state']=='current'
        cli('stop');assert cli('status',2)['state']=='stopped'
        # Static/content-only extensions must be proven through an actual extension document.
        (project/'manifest.json').write_text(json.dumps({'manifest_version':3,'name':'DevBar static extension','version':'1.0','content_scripts':[{'matches':['https://example.com/*'],'js':['worker.js']}]}))
        assert cli('sync')['state']=='current'
        cli('stop')
        print('PASS: real headless MV3 worker loading/identity, source update, new browser process, artifact digests, idempotence, content-only extension actual document and stop')
    finally:
        subprocess.run([BINARY,'stop',str(project),'--json'],env=env,capture_output=True,timeout=20)
