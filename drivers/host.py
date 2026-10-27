#!/usr/bin/env python3
"""Launch isolated actual host processes; never change a user's foreground session."""
import json, os, pathlib, shutil, subprocess, sys
bootpath, host=sys.argv[1:]; cfg=json.loads(pathlib.Path(bootpath).read_text())
folder=pathlib.Path(bootpath).parent
if cfg['strategy']=='dsh':
    binary=shutil.which('node')
    script=pathlib.Path(__file__).with_name('dsh.mjs')
    os.execv(binary,[binary,str(script),bootpath])
elif cfg['strategy']=='blender':
    script=folder/(cfg['instanceID']+'.py')
    script.write_text('''import bpy, hashlib, http.server, json, os, pathlib, uuid
c=json.loads(pathlib.Path('''+repr(bootpath)+''').read_text())
p=pathlib.Path(c['entry']); code=p.read_bytes()
if hashlib.sha256(code).hexdigest()!=c['artifactDigest']: raise RuntimeError('Entry changed')
ns={'__name__':'__main__','__file__':str(p)}
exec(compile(code,str(p),'exec'),ns)
evidence={k:c[k] for k in ['sourceDigest','syncID','target','instanceID','artifactDigest']}
evidence.update(pid=os.getpid(),platform="Blender",deviceKind="isolatedHost",runtimeVersion=bpy.app.version_string)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  if self.headers.get('Authorization')!='Bearer '+c['token']: self.send_error(403); return
  body=json.dumps(evidence).encode(); self.send_response(200); self.end_headers(); self.wfile.write(body)
 def log_message(self,*a): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
state={**evidence,'token':c['token'],'url':'http://127.0.0.1:'+str(server.server_port)}
p=pathlib.Path(c['state']); tmp=p.with_suffix('.tmp'); tmp.write_text(json.dumps(state)); tmp.chmod(0o600); tmp.replace(p)
server.serve_forever()
''')
    binary=host or '/Applications/Blender.app/Contents/MacOS/Blender'
    os.execv(binary,[binary,'--background','--factory-startup','--python-exit-code','1','--python',str(script)])
else:
    script=folder/(cfg['instanceID']+'.ts')
    script.write_text('''import {readFileSync,writeFileSync,renameSync,chmodSync} from 'node:fs';
import {createHash} from 'node:crypto';
const c=JSON.parse(readFileSync('''+json.dumps(bootpath)+''','utf8'));
const bytes=readFileSync(c.entry);
if(createHash('sha256').update(bytes).digest('hex')!==c.artifactDigest) throw Error('Entry changed');
const entry=await import(c.entry);
export default async function(api){
 await entry.default(api);
 api.on('session_start',async()=>{
 const evidence=Object.fromEntries(['sourceDigest','syncID','target','instanceID','artifactDigest'].map(k=>[k,c[k]]));
 evidence.pid=process.pid; evidence.platform="OMP"; evidence.deviceKind="isolatedHost"; evidence.runtimeVersion="Bun "+Bun.version;
 const server=Bun.serve({hostname:'127.0.0.1',port:0,fetch(req){
 if(req.headers.get('authorization')!=='Bearer '+c.token) return new Response('',{status:403});
 return Response.json(evidence);
 }});
 const p=c.state+'.tmp'; writeFileSync(p,JSON.stringify({...evidence,token:c.token,url:'http://127.0.0.1:'+server.port}));chmodSync(p,0o600);renameSync(p,c.state);
 });
}
''')
    binary=host or shutil.which('omp')
    if not binary: raise RuntimeError('OMP executable unavailable')
    child=subprocess.Popen([binary,'--mode','rpc','--no-ui','--no-extensions','--no-skills','--no-rules','--no-lsp','--no-title','--extension',str(script),'--no-session','--session-dir',str(folder/'sessions')],stdin=subprocess.PIPE)
    # Keep the real RPC input open without sending prompts/model requests.
    child.wait()
