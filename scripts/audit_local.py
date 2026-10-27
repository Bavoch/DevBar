"""Inventory local project types and explain current listeners without starting projects."""
import argparse
import datetime
import json
import os
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--root', default=str(pathlib.Path.home() / 'Coding'))
parser.add_argument('--binary', default=str(pathlib.Path(__file__).resolve().parents[1] / '.build/release/DevBar'))
parser.add_argument('--output', required=True)
args = parser.parse_args()
root = pathlib.Path(args.root)
running = json.loads(subprocess.check_output([args.binary, '--scan-json'], timeout=45))
running = [p for p in running if any(proc['canStop'] and proc['pid'] != os.getpid() for proc in p['processes'])]
by_path = {p['path']: p for p in running}
projects = []
for path in sorted(root.iterdir()):
    if not path.is_dir() or any(s in path.name.lower() for s in ['backup', 'snapshot', 'release.']): continue
    manifests = [name for name in ['package.json','Package.swift','Cargo.toml','pyproject.toml','go.mod','src-tauri/tauri.conf.json'] if (path/name).is_file()]
    types = set()
    for name in ['package.json','web/package.json','admin/package.json','worker/package.json','mobile/package.json']:
        file = path/name
        try:
            if file.stat().st_size > 512_000: continue
            package = json.loads(file.read_text())
        except (OSError, ValueError): continue
        dependencies = dict(package.get('dependencies', {}), **package.get('devDependencies', {}))
        types.update(dep for dep in ['vite','next','astro','electron','@tauri-apps/cli','wrangler','expo','react-native','express','fastify','hono'] if dep in dependencies)
    for marker, name in [('Package.swift','Swift'),('Cargo.toml','Rust'),('pyproject.toml','Python'),('go.mod','Go')]:
        if marker in manifests: types.add(name)
    if not manifests: continue
    active = by_path.get(str(path))
    projects.append({'name':path.name,'types':sorted(types),'manifests':manifests,'verification':'live' if active else 'configuration_only',
                     'ports':active['portDetails'] if active else []})
report = {'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'configurationProjects':len(projects),'runningProjects':len(running),
          'configurationOnlyProjects':sum(p['verification']=='configuration_only' for p in projects),
          'projects':projects,
          'runtime':[{**{k:p[k] for k in ['name','path','entryPoints','portDetails']},'desktop':p.get('desktop'),'primaryAction':'application' if p.get('desktop') else 'webpage' if p['entryPoints'] else 'service'} for p in running],
          'scope':'Only currently running projects have live listener verification. Stopped projects were inspected by configuration and were not started.',
          'probe':'Local headers only; no credentials, response bodies, redirect following or TLS trust bypass.',
          'regressionCoverage':['Next.js/Vite/Astro/Wrangler ownership','nested runtimes','HTML/auth pages','JSON/auth APIs','HEAD fallback','HTML error and compile-error pages','Electron/Node debugger flags','dynamic port fallback','multiple independent web apps','raw TCP/unknown','portless native/script lifecycle'],
          'limits':['Custom-domain or untrusted self-signed HTTPS may remain unconfirmed.','Docker internals and remote servers are outside local process discovery.']}
pathlib.Path(args.output).write_text(json.dumps(report,ensure_ascii=False,indent=2))
print('Audited %s configurations and %s running projects (%s stopped/configuration-only).' % (report['configurationProjects'],report['runningProjects'],report['configurationOnlyProjects']))
for p in running:
    print(p['name'], ', '.join('%s:%s' % (d['listener']['port'], d['role']) for d in p['portDetails']) or 'portless')
