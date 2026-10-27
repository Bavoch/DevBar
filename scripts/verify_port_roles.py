"""Exercise real local protocol responses, inspectors and service menu classification."""
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

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def ready(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.1): return True
    except OSError: return False

def walk(rows):
    for row in rows:
        yield row
        yield from walk(row.get('items', []))

with tempfile.TemporaryDirectory(prefix='Port roles ', dir=root / 'work') as tmp:
    project = pathlib.Path(tmp)
    (project / 'package.json').write_text('{}')
    names = ['page', 'api', 'auth', 'get_only', 'login', 'missing', 'redirect', 'debug', 'socket', 'problem', 'upgrade']
    ports = dict(zip(names, [free_port() for _ in names]))
    script = project / 'server.py'
    script.write_text('''import http.server,json,socket,sys,threading
ports=json.loads(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):
  name=self.server.role
  status={'auth':401,'get_only':405,'login':401,'missing':404,'redirect':302,'upgrade':426}.get(name,200)
  types={'api':'application/json','auth':'text/plain','problem':'application/problem+json','upgrade':'text/plain'}
  self.send_response(status)
  self.send_header('Content-Type',types.get(name,'text/html; charset=utf-8'))
  if name=='redirect': self.send_header('Location','http://not-requested.invalid/login')
  self.end_headers()
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
  # The probe must cancel at headers rather than download a response body.
  try: self.wfile.write(b'<html>'+b'x'*2000000)
  except (BrokenPipeError,ConnectionResetError): pass
 def log_message(self,*args): pass
for name,port in ports.items():
 if name=='socket':
  server=socket.socket();server.bind(('127.0.0.1',port));server.listen()
  def raw(server=server):
   while True:
    conn,_=server.accept();conn.close()
  threading.Thread(target=raw,daemon=True).start()
 else:
  server=http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler);server.role=name
  threading.Thread(target=server.serve_forever,daemon=True).start()
threading.Event().wait()
''')
    proc = subprocess.Popen([sys.executable, str(script), json.dumps(ports), '--remote-debugging-port='+str(ports['debug'])],
                            cwd=project, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if all(ready(port) for port in ports.values()): break
            time.sleep(.05)
        before = time.monotonic()
        projects = json.loads(subprocess.check_output([binary, '--scan-json'], timeout=30))
        elapsed = time.monotonic() - before
        found = next(p for p in projects if p['path'] == str(project))
        roles = {p['listener']['port']: p['role'] for p in found['portDetails']}
        expected = {'page':'webpage','api':'api','auth':'service','get_only':'webpage','login':'webpage',
                    'missing':'service','redirect':'webpage','debug':'debug','socket':'unknown','problem':'api','upgrade':'service'}
        assert roles == {ports[k]: v for k,v in expected.items()}, roles
        assert {e['port'] for e in found['entryPoints']} == {ports[k] for k,v in expected.items() if v=='webpage'}
        assert len(found['listeners']) == len(ports), 'Every listener must remain accounted for'
        menus = json.loads(subprocess.check_output([binary, '--menu-json'], timeout=30))
        menu = next(row['items'] for row in menus if row['title'] == project.name)
        copies = [row for row in walk(menu) if row.get('action') == 'copyURL:']
        expected_urls = {f"{e['scheme']}://localhost:{e['port']}" for e in found['entryPoints']}
        assert {row['value'] for row in copies} == expected_urls
        assert elapsed < 12, 'Protocol probing must remain bounded and parallel'
        print('PASS: HTML, JSON API, auth service/login, GET-only, redirects, HTML 404, debugger HTML, raw TCP, JSON suffix and WebSocket-upgrade responses')
        print('PASS: all listeners explained; page addresses copyable; scan bounded to %.2fs' % elapsed)
    finally:
        try: os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        proc.wait(timeout=5)
