"""Read real icon resources and inspect native menu images without opening UI."""
import json
import os
import sys
import pathlib
import struct
import subprocess
import tempfile
import zlib

root = pathlib.Path(__file__).resolve().parents[1]
binary = os.environ.get('DEVBAR_TEST_BINARY', str(root / '.build/release/DevBar'))
(root / 'work').mkdir(exist_ok=True)

def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 1, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00\xff\x00\x00\xff\xff')) + chunk(b'IEND', b''))

def icon(path):
    result = json.loads(subprocess.check_output([binary, '--icon-project', str(path)]))
    if result['found']:
        assert result['pixels'] == [64, 64], 'All sources must normalize to small retina images'
    return result

with tempfile.TemporaryDirectory(prefix='Icons ', dir=root / 'work') as folder:
    project = pathlib.Path(folder)
    (project / 'public').mkdir()
    (project / 'public/brand.png').write_bytes(png())
    (project / 'public/favicon.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="14" fill="#ed4f35"/></svg>')
    (project / 'index.html').write_text('<link href="/brand.png?v=2" REL="shortcut icon">')
    assert icon(project)['source'].endswith('/public/brand.png')
    (project / 'index.html').write_text('<link rel="icon" href="https://example.invalid/favicon.png">')
    assert icon(project)['source'].endswith('/public/favicon.svg'), 'Remote links must fall through to local assets'
    (project / 'public/favicon.svg').write_text('invalid icon')
    assert not icon(project)['found'], 'Corrupt images must use the fallback'

    (project / 'src-tauri/icons').mkdir(parents=True)
    (project / 'src-tauri/icons/project.png').write_bytes(png())
    (project / 'src-tauri/tauri.conf.json').write_text(json.dumps({'bundle': {'icon': ['icons/project.png']}}))
    assert icon(project)['source'].endswith('/src-tauri/icons/project.png')
    (project / 'src-tauri/tauri.conf.json').unlink()
    (project / 'index.html').write_text('<link rel="icon" href="../../outside.png">')
    assert not icon(project)['found'], 'Icon links must stay inside the project'

    (project / 'index.html').write_text('<link rel="icon" href="/brand.png">')
    env = dict(os.environ, DEVBAR_DATA_DIR=str(project / 'state'))
    subprocess.run([binary, '--add-project', str(project), '--name', 'Icon fixture', '--command', 'echo fixture'], env=env, check=True, stdout=subprocess.DEVNULL)
    rows = json.loads(subprocess.check_output([binary, '--menu-json'], env=env))
    row = next(row for row in rows if row['title'] == 'Icon fixture')
    assert row['hasIcon'] and row['iconIsTemplate'] is False, 'Stopped project menu must consume the colorful project icon'

    (project / 'public/brand.png').unlink()
    rows = json.loads(subprocess.check_output([binary, '--menu-json'], env=env))
    row = next(row for row in rows if row['title'] == 'Icon fixture')
    assert row['hasIcon'] and row['iconIsTemplate'] is True, 'Missing icon must retain a consistent template fallback'
    print('PASS: declared icons, SVG/PNG rendering, Tauri icons, corrupt/missing fallback, local path boundaries and native menu consumption')

with tempfile.TemporaryDirectory(prefix='Nested icons ', dir=root / 'work') as folder:
    project = pathlib.Path(folder)
    (project / 'icons').mkdir()
    (project / 'icons/tiny.png').write_bytes(png())
    (project / 'icons/store.png').write_bytes(png())
    manifest = project / 'manifest.json'
    manifest.write_text(json.dumps({'manifest_version': 3, 'icons': {
        '16': 'icons/tiny.png', '128': 'icons/store.png', '256': 'icons/missing.png'
    }}))
    assert icon(project)['source'].endswith('/icons/store.png'), 'Prefer the largest usable declared extension icon'
    manifest.write_text(json.dumps({'manifest_version': 3, 'action': {'default_icon': 'icons/tiny.png'}}))
    assert icon(project)['source'].endswith('/icons/tiny.png')
    manifest.unlink()

    web = project / 'web'
    (web / 'public/brand').mkdir(parents=True)
    (web / 'index.html').write_text('<link rel="manifest" href="/brand/site.webmanifest">')
    (web / 'public/brand/site.webmanifest').write_text(json.dumps({'icons': [{'src': 'project.png'}]}))
    (web / 'public/brand/project.png').write_bytes(png())
    assert icon(project)['source'].endswith('/web/public/brand/project.png'), 'Web URLs resolve from the child application'

    (project / '.git').mkdir()
    (project / 'icon.png').write_bytes(png())
    child = project / 'native'
    child.mkdir()
    assert icon(child)['source'] == str(project / 'icon.png')
    (child / '.git').mkdir()
    assert not icon(child)['found'], 'Do not inherit across a nested checkout'
    print('PASS: browser extension declarations, linked web manifests, child web roots and Git icon boundaries')

# Optional real-project acceptance is explicit and read-only.
for argument in sys.argv[1:]:
    project = pathlib.Path(argument).expanduser().resolve(strict=True)
    result = icon(project)
    assert result['found'], f'{project.name} has no usable local icon'
    print(f"PASS: {project.name}: {os.path.relpath(result['source'], project)}")
