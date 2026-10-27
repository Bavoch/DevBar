"""Exercise public/internal HTTP ports with real framework-shaped process trees."""
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
(root / 'work').mkdir(exist_ok=True)

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def ready(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=0.1):
            return True
    except OSError:
        return False

with tempfile.TemporaryDirectory(prefix='Entry ports ', dir=root / 'work') as folder:
    project = pathlib.Path(folder)
    (project / 'package.json').write_text('{"scripts":{"dev":"next dev"}}')
    runtime = project / 'runtime.py'
    runtime.write_text('''import http.server,sys
class Handler(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
 def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),Handler).serve_forever()
''')
    next_script = project / 'next'
    next_script.write_text('''import argparse,http.server,subprocess,sys,threading
parser=argparse.ArgumentParser()
parser.add_argument('--port',type=int)
parser.add_argument('--public',type=int)
parser.add_argument('--internal',type=int)
parser.add_argument('--child-port',type=int)
args=parser.parse_args()
class Page(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):
  self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.end_headers()
 def log_message(self,*args): pass
class Control(Page):
 def do_HEAD(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
subprocess.Popen([sys.executable,'runtime.py',str(args.child_port)])
server=http.server.ThreadingHTTPServer(('127.0.0.1',args.internal),Control)
threading.Thread(target=server.serve_forever,daemon=True).start()
http.server.ThreadingHTTPServer(('127.0.0.1',args.port or args.public),Page).serve_forever()
''')

    for flag in ['--port', '--public']:
        public, internal, child = free_port(), free_port(), free_port()
        proc = subprocess.Popen([sys.executable,str(next_script),flag,str(public),'--internal',str(internal),'--child-port',str(child)],
                                cwd=project,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        independent = None
        try:
            for _ in range(100):
                if all(ready(p) for p in [public,internal,child]): break
                time.sleep(0.05)
            rows=json.loads(subprocess.check_output([binary,'--scan-json']))
            found=next(p for p in rows if p['path']==str(project))
            assert [p['port'] for p in found['entryPoints']]==[public], found
            assert {p['port'] for p in found['auxiliaryServices']}=={internal,child}
            assert len(found['listeners'])==3, 'Diagnostic listeners must remain intact'
            menus=json.loads(subprocess.check_output([binary,'--menu-json']))
            menu=next(row['items'] for row in menus if row['title']==project.name)
            entry=next(row for row in menu if row['title']=='打开网页')
            assert entry['value']==f'http://localhost:{public}' and not entry['items']
            if flag=='--port':
                extra=free_port()
                independent=subprocess.Popen([sys.executable,'-m','http.server',str(extra),'--bind','127.0.0.1'],cwd=project,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                for _ in range(100):
                    if ready(extra): break
                    time.sleep(0.05)
                rows=json.loads(subprocess.check_output([binary,'--scan-json']))
                found=next(p for p in rows if p['path']==str(project))
                assert {p['port'] for p in found['entryPoints']}=={public,extra}, 'Independent services must remain available'
            print('PASS:', 'declared bind' if flag=='--port' else 'HTTP fallback', 'keeps the real high-port page and excludes same-process and child control APIs')
        finally:
            if independent is not None:
                independent.terminate(); independent.wait(timeout=5)
            try: os.killpg(proc.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            proc.wait(timeout=5)

    generic = project / 'generic.py'
    generic.write_text('''import http.server,sys,threading
class API(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):
  self.send_response(401); self.send_header('Content-Type','application/json'); self.end_headers()
 def log_message(self,*args): pass
class Page(API):
 def do_HEAD(self):
  self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.end_headers()
class Missing(API):
 def do_HEAD(self):
  self.send_response(404); self.send_header('Content-Type','text/html'); self.end_headers()
for port,handler in zip(sys.argv[1:],[API,Page,Missing]):
 server=http.server.ThreadingHTTPServer(('127.0.0.1',int(port)),handler)
 threading.Thread(target=server.serve_forever,daemon=True).start()
threading.Event().wait()
''')
    api, page, missing = free_port(), free_port(), free_port()
    proc = subprocess.Popen([sys.executable,str(generic),str(api),str(page),str(missing)],
                            cwd=project,start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if all(ready(p) for p in [api,page,missing]): break
            time.sleep(0.05)
        rows=json.loads(subprocess.check_output([binary,'--scan-json']))
        found=next(p for p in rows if p['path']==str(project))
        assert [p['port'] for p in found['entryPoints']]==[page], found
        assert {p['port'] for p in found['auxiliaryServices']}=={api,missing}
        assert len(found['listeners'])==3
        menus=json.loads(subprocess.check_output([binary,'--menu-json']))
        menu=next(row['items'] for row in menus if row['title']==project.name)
        entry=next(row for row in menu if row['title']=='打开网页')
        assert entry['value']==f'http://localhost:{page}' and not entry['items']
        print('PASS: ordinary runtime keeps HTML page, excludes authenticated JSON API and HTML error page; direct menu link remains')
    finally:
        try: os.killpg(proc.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        proc.wait(timeout=5)
