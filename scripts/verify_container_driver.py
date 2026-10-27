"""Actual Linux image rebuild/container replacement and application runtime proof."""
from pathlib import Path
import json,os,socket,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];BINARY=os.environ.get('DEVBAR_TEST_BINARY',str(ROOT/'.build/release/DevBar'))
context=os.environ.get('DEVBAR_DOCKER_CONTEXT','colima-devbar')
with tempfile.TemporaryDirectory(prefix='Container sync ',dir=ROOT/'work') as directory:
 root=Path(directory);(root/'work').mkdir()
 with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
 name='devbar-e2e-'+str(os.getpid())
 (root/'Dockerfile').write_text('FROM python:3.12-alpine\nARG DEVBAR_SOURCE_DIGEST\nWORKDIR /app\nCOPY server.py /app/server.py\nRUN printf "%s" "$DEVBAR_SOURCE_DIGEST" > /app/revision\nCMD ["python3","/app/server.py"]\n')
 (root/'server.py').write_text('''import http.server,os,json,pathlib,uuid
proof=dict(sourceDigest=pathlib.Path('/app/revision').read_text(),syncID=os.environ['DEVBAR_SYNC_ID'],target=os.environ['DEVBAR_SYNC_TARGET'],instanceID=str(uuid.uuid4()),pid=os.getpid(),revision='v1')
pathlib.Path('/data/preserved').touch(exist_ok=True)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  value=json.dumps(proof).encode();self.send_response(200);self.end_headers();self.wfile.write(value)
http.server.HTTPServer(('0.0.0.0',8080),Handler).serve_forever()
''')
 compose={'services':{'app':{'build':'.','ports':[f'127.0.0.1:{port}:8080'],'volumes':['data:/data']}},'volumes':{'data':{}}}
 (root/'compose.json').write_text(json.dumps(compose));(root/'.dockerignore').write_text('work\n.devbar.json\n')
 (root/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'container':{'strategy':'dockerCompose','composeFile':'compose.json','service':'app','projectName':name,'dockerContext':context,'proofURL':f'http://127.0.0.1:{port}/','timeout':600}}}))
 env=dict(os.environ,DEVBAR_DATA_DIR=str(root/'work/state'))
 def cli(action,expected=0):
  p=subprocess.run([BINARY,action,str(root),'--target','container','--json'],capture_output=True,text=True,env=env,timeout=700)
  assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
  return json.loads(p.stdout)
 try:
  one=cli('sync');assert one['state']=='current'
  first=one['receipt']['proof'];assert cli('status')['state']=='current'
  entry=root/'server.py';entry.write_text(entry.read_text().replace("revision='v1'","revision='v2'"))
  assert cli('status',2)['state']=='sourceChanged'
  two=cli('sync');second=two['receipt']['proof'];assert first['instanceID']!=second['instanceID'] and first['artifactDigest']!=second['artifactDigest']
  assert cli('sync')['receipt']['syncID']==two['receipt']['syncID']
  cid=second['instanceID'].split(':')[0]
  subprocess.run(['docker','--context',context,'exec',cid,'test','-f','/data/preserved'],check=True)
  cli('stop');assert cli('status',2)['state']=='unconfirmed'
  evidence={'passed':True,'platform':'Linux container on local Apple Virtualization VM','v1':first,'v2':second,'preservedVolume':True}
  (ROOT/'work/container-driver-evidence.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
 finally:
  endpoint=json.loads(subprocess.check_output(['docker','context','inspect',context],text=True))[0]['Endpoints']['docker']['Host']
  subprocess.run(['docker-compose','-p',name,'-f',str(root/'compose.json'),'down','--volumes'],env=dict(os.environ,DOCKER_HOST=endpoint),capture_output=True,timeout=60)
