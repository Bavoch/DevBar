"""Agent control listeners must not impersonate project services or get stopped."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root=Path(__file__).resolve().parents[1]
binary=str(root/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Agent ports ',dir=root/'work') as folder:
    base=Path(folder)
    project=base/'Project'
    project.mkdir()
    (project/'package.json').write_text('{"scripts":{"dev":"vite --port 5111"}}')
    agent=base/'node_modules/@deepseek-ai/dsh/lib/bin.js'
    agent.parent.mkdir(parents=True)
    agent.write_text('''import http.server,json,pathlib,subprocess,sys,threading,signal
signal.signal(signal.SIGTERM,signal.SIG_IGN)
class Control(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):
  self.send_response(401);self.send_header('Content-Type','application/json');self.end_headers()
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Control)
pathlib.Path('control-port').write_text(str(server.server_port))
if sys.argv[1]=='child':
 child=subprocess.Popen([sys.executable,'-m','http.server','0','--bind','127.0.0.1'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,preexec_fn=lambda:signal.signal(signal.SIGTERM,signal.SIG_DFL))
 pathlib.Path('child-pid').write_text(str(child.pid))
server.serve_forever()
''')
    env=dict(os.environ,DEVBAR_DATA_DIR=str(base/'state'))
    def cli(*args):
        result=subprocess.run([binary,*args],env=env,capture_output=True,text=True,timeout=45)
        assert result.returncode == 0, result.stderr
        return result.stdout
    def scan():
        return next((p for p in json.loads(cli('--scan-json')) if p['path']==str(project)),None)
    process=None; child=None
    try:
        process=subprocess.Popen([sys.executable,str(agent),'alone','--system-prompt','vite --port 5111 node --inspect=9229'],cwd=project)
        time.sleep(.25)
        assert scan() is None, 'Agent control listener must not count as a running project'
        # A wrapper around a tool must not keep the project running, either.
        wrapper=base/'wrapper.mjs'
        wrapper.write_text("import {spawn} from 'node:child_process'; spawn(process.argv[2],process.argv.slice(3),{stdio:'ignore'}); setInterval(()=>{},1000);")
        wrapped=subprocess.Popen(['node',str(wrapper),sys.executable,str(agent),'alone'],cwd=project)
        try:
            time.sleep(.3)
            assert scan() is None, 'Tool-only wrappers must not appear as projects'
        finally:
            # Fixture descendants are identified directly, never by process name.
            children=subprocess.check_output(['pgrep','-P',str(wrapped.pid)],text=True).split()
            for pid in children: os.kill(int(pid),9)
            wrapped.terminate();wrapped.wait(timeout=5)
        process.kill();process.wait(timeout=5)
        process=subprocess.Popen([sys.executable,str(agent),'child','--system-prompt','vite --port 5111'],cwd=project)
        for _ in range(40):
            if (project/'child-pid').exists(): break
            time.sleep(.05)
        child=int((project/'child-pid').read_text())
        time.sleep(.2)
        result=scan()
        assert result and len(result['entryPoints'])==1
        assert result['entryPoints'][0]['pid']==child
        control=int((project/'control-port').read_text())
        assert next(p for p in result['portDetails'] if p['listener']['port']==control)['role']=='tool'
        assert not next(p for p in result['processes'] if p['pid']==process.pid)['canStop']
        ident=cli('--add-project',str(project),'--command','').strip()
        cli('--stop-project',ident)
        assert process.poll() is None, 'Stopping project must preserve its coding agent'
        assert scan() is None
        print('PASS: DSH control API and tool-only wrapper excluded; prompt/config cannot impersonate Vite; real child webpage stops while SIGTERM-resistant DSH survives')
    finally:
        if child:
            try: os.kill(child,15)
            except ProcessLookupError: pass
        if process and process.poll() is None:
            process.kill();process.wait(timeout=5)
