"""Loopback-only static development server with automatic document reload."""
import hashlib
import http.server
import io
import json
import os
import pathlib
import secrets
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
page = pathlib.Path(sys.argv[2]).resolve()
if not page.is_relative_to(root):
    raise RuntimeError('Static entry is outside the project')
route = '/__devbar_live_' + secrets.token_hex(16)
ignored = {'.git', 'node_modules', '.venv', 'venv', '__pycache__', 'output', 'outputs', 'work', '.cache'}

def revision():
    digest = hashlib.sha256()
    for folder, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(d for d in directories if d not in ignored and not pathlib.Path(folder, d).is_symlink())
        for name in sorted(files):
            file = pathlib.Path(folder, name)
            if file.is_symlink() or file.suffix in {'.log', '.pid'}:
                continue
            try:
                stat = file.stat()
                digest.update(f'{file.relative_to(root)}:{stat.st_mtime_ns}:{stat.st_size}'.encode())
            except FileNotFoundError:
                pass
    return digest.hexdigest()

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(root), **kwargs)

    def send_head(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == route:
            data = json.dumps(revision()).encode()
            return self.body(data, 'application/json')
        file = pathlib.Path(self.translate_path(self.path)).resolve()
        if not file.is_relative_to(root):
            self.send_error(403)
            return None
        if file.is_dir():
            file /= 'index.html'
        if file.suffix.lower() in {'.html', '.htm'} and file.is_file():
            # Measure before reading: a save during the response causes a reload.
            current = revision()
            client = '''<script>(()=>{const initial=VERSION;let stopped=false;
addEventListener('pagehide',()=>{stopped=true});
async function check(){if(stopped)return;try{const response=await fetch(ROUTE,{cache:'no-store'});
if(response.ok&&await response.json()!==initial){location.reload();return;}}catch{}
setTimeout(check,750)}check()})()</script>'''.replace('VERSION', json.dumps(current)).replace('ROUTE', json.dumps(route))
            return self.body(file.read_bytes() + client.encode(), 'text/html; charset=utf-8')
        return super().send_head()

    def body(self, data, content_type):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        return io.BytesIO(data)

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(f'DevBar static development: http://127.0.0.1:{server.server_port}/' + page.relative_to(root).as_posix(), flush=True)
server.serve_forever()
