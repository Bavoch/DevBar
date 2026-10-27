"""Actual, serial acceptance of deduplicated automatic targets. Own sessions only."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--inventory', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--kind', choices=['static', 'frontend', 'extension', 'ios', 'host', 'worker', 'graph'], required=True)
parser.add_argument('--project', action='append', default=[])
args = parser.parse_args()
binary = str(ROOT / '.build/release/DevBar')
projects = json.loads(Path(args.inventory).read_text())['projects']
out = Path(args.output)
results = []
seen = set()
class AcceptanceDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        # Xcode helpers can finish writing DerivedData just after the build command returns.
        for attempt in range(30):
            try:
                return super().cleanup()
            except OSError:
                if attempt == 29: raise
                time.sleep(.2)

with AcceptanceDirectory(prefix='Automatic acceptance ', dir=ROOT / 'work') as directory:
    env = dict(os.environ, DEVBAR_DATA_DIR=directory, DEVBAR_HEADLESS='1', BROWSER='none')
    def cli(action, project, target=None, *flags):
        cmd = [binary, action, project, '--json'] + (['--target', target] if target else []) + list(flags)
        p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=1000)
        try: value = json.loads(p.stdout)
        except ValueError: value = {'state': 'failed', 'reason': 'CLI returned no valid JSON', 'exitCode': p.returncode}
        return value
    def save():
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({'kind': args.kind, 'results': results, 'counts': {state: sum(r['state'] == state for r in results) for state in {r['state'] for r in results}}}, ensure_ascii=False, indent=2) + '\n')
    for project in projects:
        path = project['path']
        if args.project and path not in args.project: continue
        if project['role'] == 'archive': continue
        for target in project.get('automaticSyncTargets', []):
            launch = next((t for t in project['profile']['targets'] if t['id'] == target), None)
            kinds = {'static': 'staticWeb', 'frontend': 'web', 'extension': 'browserExtension', 'ios': 'ios'}
            if args.kind in ['worker', 'graph']:
                if launch is None or launch['directory'] != path: continue
            elif args.kind == 'host':
                if target not in ['omp', 'dsh']: continue
            elif launch is None or launch['kind'] != kinds[args.kind]: continue
            if launch:
                directory = launch['directory']
                local_id = target.removeprefix(os.path.relpath(directory, path) + ':') if directory != path else target
                if directory != path: continue
                if (directory, local_id) in seen: continue
                seen.add((directory, local_id))
                if directory != path: continue  # Visit the canonical child record once.
            plan = cli('sync', path, target, '--plan')
            if plan.get('state') != 'planned':
                results.append({'project': path, 'target': target, 'state': plan.get('state'), 'reason': plan.get('reason')}); save(); continue
            config = plan['plan'].get('configuration', {})
            if args.kind in ['worker','graph'] and config.get('runtimeWitness') != {'worker':'workerHTTP','graph':'nodeGraph'}[args.kind]: continue
            if args.kind == 'frontend':
                if config.get('runtimeWitness') != 'nodeHTTP': continue
                package = json.loads((Path(path) / 'package.json').read_text())
                script = package.get('scripts', {}).get(target, '')
                if not (script.startswith('npm run build:h5') or any(script.startswith(prefix) for prefix in ['vite', 'next dev', 'astro dev', 'remix dev', 'docusaurus start', 'npx --yes vite', 'npx vite'])): continue
            cli('doctor', path)
            cli('init', path, target, '--plan')
            report = {'project': path, 'target': target}
            value = {}
            try:
                value = cli('sync', path, target)
                report.update(state=value['state'], reason=value.get('reason'))
                if value['state'] == 'current':
                    status = cli('status', path, target)
                    report['state'] = status['state']
                    if status['state'] != 'current': report['reason'] = status.get('reason')
                    receipt = status.get('receipt', {})
                    report['syncID'] = receipt.get('syncID')
                    report['proof'] = receipt.get('proof')
                    # For static content, confirm the selected document was actually served.
                    if args.kind in ['static', 'frontend']:
                        witnesses = list((Path(env['DEVBAR_DATA_DIR']) / 'sync/witnesses').rglob('*.json'))
                        record = next(json.loads(f.read_text()) for f in witnesses if json.loads(f.read_text())['syncID'] == receipt['syncID'])
                        from urllib.parse import urlsplit, urlunsplit, quote
                        parts = urlsplit(record['entryURL'].replace('#', '%23'))
                        url = urlunsplit((parts.scheme, parts.netloc, quote(parts.path, safe='/%'), '', ''))
                        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(url, timeout=90) as response:
                            report['documentHTTP'] = response.status
                            body = response.read(2_000_000)
                            report['servedHTML'] = b'<html' in body.lower() or b'<!doctype html' in body.lower()
                            if args.kind == 'frontend' and not report['servedHTML']: raise RuntimeError('Frontend did not return an HTML document')
                    if report['state'] == 'current':
                        repeat = cli('sync', path, target)
                        assert repeat.get('receipt', {}).get('syncID') == receipt['syncID'], 'Idempotence: '+json.dumps({k:repeat.get(k) for k in ['state','reason']},ensure_ascii=False)
            except Exception as error:
                report.update(state='failed', reason=str(error))
            finally:
                if value.get('log') and Path(value['log']).is_file():
                    import hashlib, shutil
                    log = out.parent / ('acceptance-'+hashlib.sha256((path+target).encode()).hexdigest()[:12]+'.log')
                    shutil.copyfile(value['log'],log)
                    if report['state'] != 'current': report['log'] = str(log)
                stopped = cli('stop', path, target)
                report['stopState'] = stopped.get('state')
                results.append(report); save()
                print(json.dumps({k: report[k] for k in ['project','target','state']}, ensure_ascii=False), flush=True)
print(json.dumps({'kind': args.kind, 'tested': len(results), 'counts': {state: sum(r['state'] == state for r in results) for state in {r['state'] for r in results}}}, ensure_ascii=False))
