"""Automatic recipes and real serving runtime attestation, without project configuration."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('DEVBAR_TEST_BINARY', str(ROOT / '.build/release/DevBar'))
with tempfile.TemporaryDirectory(prefix='Automatic sync ', dir=ROOT / 'work') as directory:
    base = Path(directory)
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / 'state'), DEVBAR_HEADLESS='1')
    def cli(action, project, *args, code=0):
        p = subprocess.run([BINARY, action, str(project), *args, '--json'], env=env, capture_output=True, text=True, timeout=150)
        assert p.returncode == code, (p.returncode, p.stdout, p.stderr)
        return json.loads(p.stdout)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for kind in ['node', 'static']:
        project = base / (kind + ' project with spaces')
        project.mkdir()
        if kind == 'node':
            (project / 'package.json').write_text(json.dumps({'workspaces': ['apps/*']}))
            project = project / 'apps/frontend'
            project.mkdir(parents=True)
            shared = project.parent / 'shared'
            shared.mkdir()
            (shared / 'favicon.ico').write_text('shared asset')
            (project / 'favicon.ico').symlink_to(shared / 'favicon.ico')
        if kind == 'node':
            (project / 'package.json').write_text(json.dumps({'scripts': {'dev:web': 'node server.cjs'}}))
            (project / 'server.cjs').write_text("const http=require('node:http');process.env.DEVBAR_SOURCE_DIGEST='WRONG';const revision='v1';http.createServer((q,s)=>{s.writeHead(404);s.end('compiler');}).listen(0,'127.0.0.1');http.createServer((q,s)=>{s.setHeader('Content-Type','text/html');s.end('<html>'+revision+'</html>');}).listen(0,'127.0.0.1');")
            target, source = 'dev:web', project / 'server.cjs'
        else:
            (project / 'a # page.html').write_text('<title>v1</title>')
            target, source = 'static:a # page.html', project / 'a # page.html'
        cli('doctor', project)
        draft = cli('init', project, '--target', target, '--plan')
        assert next(iter(draft['configuration']['targets'].values()))['runtimeWitness'] == ('nodeHTTP' if kind == 'node' else 'staticHTTP')
        assert not (project / '.devbar.json').exists()
        assert cli('sync', project, '--target', target, '--plan')['state'] == 'planned'
        try:
            one = cli('sync', project, '--target', target)
            assert one['state'] == 'current', one
            assert one['receipt']['proof']['sourceDigest'] != 'WRONG'
            assert cli('status', project, '--target', target)['state'] == 'current'
            if kind == 'node':
                (project.parent.parent / '.astro').mkdir(exist_ok=True)
                (project.parent.parent / '.astro/generated.json').write_text('generated cache')
                assert cli('status', project, '--target', target)['state'] == 'current'
            assert cli('sync', project, '--target', target)['receipt']['syncID'] == one['receipt']['syncID']
            source.write_text(source.read_text().replace('v1', 'v2'))
            assert cli('status', project, '--target', target, code=2)['state'] == 'sourceChanged'
            two = cli('sync', project, '--target', target)
            assert two['state'] == 'current' and two['receipt']['proof']['pid'] != one['receipt']['proof']['pid']
            assert two['receipt']['sourceDigest'] != one['receipt']['sourceDigest']
            if kind == 'static':
                records = [json.loads(f.read_text()) for f in (base / 'state/sync/witnesses').rglob('*.json')]
                record = next(r for r in records if r['syncID'] == two['receipt']['syncID'])
                url = record['entryURL'].replace(' ', '%20').replace('#', '%23')
                assert b'v2' in opener.open(url, timeout=5).read()
            assert not (project / '.devbar.json').exists()
            cli('stop', project, '--target', target)
            assert cli('status', project, '--target', target, code=2)['state'] == 'stopped'
        finally:
            subprocess.run([BINARY, 'stop', str(project), '--target', target, '--json'], env=env, capture_output=True, timeout=30)
    print('PASS: zero-config Node and exact static page, read-only draft, independently measured digest, actual runtime HTTP proof/PID, v1→v2, no source mutation, idempotence and stop')
