"""An inactive desktop target must not hide a running webpage."""
import json
import os
import pathlib
import plistlib
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
subprocess.run([binary, '--self-test-desktop'], check=True)
with tempfile.TemporaryDirectory(prefix='Desktop with page ', dir=root / 'work') as tmp:
    project = pathlib.Path(tmp)
    (project / 'package.json').write_text(json.dumps({'main':'main.cjs','devDependencies':{'electron':'1'}}))
    (project / 'electron-builder.json').write_text(json.dumps({'appId':'dev.devbar.fixture','productName':'DesktopFixture'}))
    app = project / 'out/mac-arm64/DesktopFixture.app'
    executable = app / 'Contents/MacOS/DesktopFixture'
    executable.parent.mkdir(parents=True)
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o700)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.devbar.fixture','CFBundleExecutable':'DesktopFixture','CFBundlePackageType':'APPL'}))
    (project / 'index.html').write_text('<html><title>Unrelated OTA installer</title></html>')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    process = subprocess.Popen([sys.executable,'-m','http.server',str(port),'--bind','127.0.0.1'],cwd=project,
                               stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1): break
            except OSError: time.sleep(.05)
        menus = json.loads(subprocess.check_output([binary,'--menu-json']))
        menu = next(row['items'] for row in menus if row['title']==project.name)
        primary = next(row for row in menu if row['title']=='打开网页')
        assert primary['action']=='openURL:' and primary['value']==f'http://localhost:{port}'
        assert not any(row.get('action')=='openDesktop:' for row in menu)
        more = next(row['items'] for row in menu if row['title']=='更多')
        assert not any(row['title']=='附属网页' for row in more)
        selected = json.loads(subprocess.check_output([binary,'--desktop-project',str(project)]))
        assert selected['identifier']=='dev.devbar.fixture' and not selected.get('pid'), selected
        print('PASS: a running webpage is primary when the detected desktop app is stopped; no browser or fixture App launch')
    finally:
        os.killpg(process.pid,signal.SIGTERM)
        process.wait(timeout=5)
