"""Serve an exact static project, with an independently measured in-runtime revision."""
import functools
import http.server
import json
import os
import pathlib
import subprocess
import sys
import threading

root, page = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
if not page.is_relative_to(root):
    raise RuntimeError('Static entry is outside the project')
env = dict(os.environ, DEVBAR_WITNESS_PID=str(os.getpid()))
env.pop('NODE_OPTIONS', None)
measured = json.loads(subprocess.check_output([
    env['DEVBAR_WITNESS_BINARY'], '--runtime-source', env['DEVBAR_PROJECT_PATH'],
    '--target', env['DEVBAR_SYNC_TARGET']], env=env, timeout=60, text=True))
proof = dict(measured, syncID=env['DEVBAR_SYNC_ID'], target=env['DEVBAR_SYNC_TARGET'], pid=os.getpid(), runtimeVersion=sys.version.split()[0])
route = '/' + proof['syncID'] + '/' + str(os.getpid())
class Witness(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != route:
            self.send_error(404)
            return
        body = json.dumps(proof).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root)))
witness = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Witness)
threading.Thread(target=witness.serve_forever, daemon=True).start()
folder = pathlib.Path(env['DEVBAR_WITNESS_DIRECTORY'])
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
record = dict(proof, witnessURL=f'http://127.0.0.1:{witness.server_port}{route}', entryURL=f'http://127.0.0.1:{server.server_port}/' + page.relative_to(root).as_posix())
file = folder / (str(os.getpid()) + '.json')
tmp = file.with_suffix('.tmp')
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as output: json.dump(record, output)
tmp.replace(file)
try: server.serve_forever()
finally:
    file.unlink(missing_ok=True)
    witness.shutdown()
