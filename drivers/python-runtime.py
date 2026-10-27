"""Run a declared Python console entry and witness the source code actually loaded by Python."""
import hashlib
import http.server
import importlib
import importlib.machinery
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

entry, name, source = sys.argv[1:4]
module_name, function_name = entry.split(':', 1)
root = pathlib.Path(os.environ['DEVBAR_PROJECT_PATH']).resolve()
expected_entry = pathlib.Path(source).resolve()
if not expected_entry.is_relative_to(root) or module_name in sys.modules:
    raise RuntimeError('Python entry cannot be independently measured')
# Keep normal sitecustomize/venv startup intact; instrument only project source imports.
sys.path = [os.getcwd()] + [p for p in sys.path if pathlib.Path(p or '.').resolve() != pathlib.Path(__file__).parent.resolve()]
original = importlib.machinery.SourceFileLoader.get_code
loaded = {}
def get_code(loader, fullname):
    filename = pathlib.Path(loader.path).resolve()
    if filename.is_relative_to(root) and not any(p in filename.relative_to(root).parts for p in ['.venv','venv','node_modules']):
        data = filename.read_bytes()
        code = compile(data, loader.path, 'exec', dont_inherit=True, optimize=sys.flags.optimize)
        loaded[str(filename)] = hashlib.sha256(data).hexdigest()
        return code
    return original(loader, fullname)
importlib.machinery.SourceFileLoader.get_code = get_code
module = importlib.import_module(module_name)
if str(expected_entry) not in loaded:
    raise RuntimeError('Declared Python entry was not loaded from current project source')
function = module
for part in function_name.split('.'): function = getattr(function, part)
sys.argv = [name]
def publish():
    time.sleep(.2)
    env = dict(os.environ, DEVBAR_WITNESS_PID=str(os.getpid()))
    env.pop('NODE_OPTIONS', None)
    measured = json.loads(subprocess.check_output([env['DEVBAR_WITNESS_BINARY'],'--runtime-source',str(root),'--target',env['DEVBAR_SYNC_TARGET']],env=env,text=True,timeout=60))
    proof = dict(measured, syncID=env['DEVBAR_SYNC_ID'], target=env['DEVBAR_SYNC_TARGET'], pid=os.getpid(), runtimeVersion='Python '+sys.version.split()[0])
    route = '/' + proof['syncID'] + '/' + str(os.getpid())
    class Witness(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != route:
                self.send_error(404); return
            if any(not pathlib.Path(f).is_file() or hashlib.sha256(pathlib.Path(f).read_bytes()).hexdigest()!=digest for f,digest in list(loaded.items())):
                self.send_error(409); return
            body=json.dumps(proof).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
        def log_message(self,*args): pass
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Witness)
    folder=pathlib.Path(env['DEVBAR_WITNESS_DIRECTORY']);folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    file=folder/(str(os.getpid())+'.json')
    fd=os.open(file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output:json.dump(dict(proof,witnessURL=f'http://127.0.0.1:{server.server_port}{route}'),output)
    server.serve_forever()
threading.Thread(target=publish,daemon=True).start()
result=function()
raise SystemExit(result)
