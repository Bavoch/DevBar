"""Verify source actually imported by the Python interpreter, including a stale pyc trap."""
import json,os,py_compile,subprocess,sys,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BINARY=str(ROOT/'.build/release/DevBar')
with tempfile.TemporaryDirectory(prefix='Python automatic ',dir=ROOT/'work') as folder:
    project=Path(folder);(project/'src/sample').mkdir(parents=True);(project/'.venv/bin').mkdir(parents=True)
    (project/'.venv/bin/python').symlink_to(sys.executable)
    (project/'pyproject.toml').write_text('[project]\nname="sample"\n[project.scripts]\nsample="sample.cli:main"\n')
    (project/'src/sample/__init__.py').write_text('')
    source=project/'src/sample/cli.py'
    code="from pathlib import Path\nimport time\nREVISION='v1'\ndef main():\n Path('work').mkdir(exist_ok=True)\n Path('work/loaded.txt').write_text(REVISION)\n while True: time.sleep(.1)\n"
    source.write_text(code);stamp=source.stat().st_mtime;py_compile.compile(str(source),doraise=True)
    env=dict(os.environ,DEVBAR_DATA_DIR=str(project/'work/state'),PYTHONPATH=str(project/'src'),DEVBAR_HEADLESS='1')
    def cli(action,code=0):
        p=subprocess.run([BINARY,action,str(project),'--target','python:sample','--json'],env=env,capture_output=True,text=True,timeout=100)
        assert p.returncode==code,(p.returncode,p.stdout,p.stderr)
        return json.loads(p.stdout)
    try:
        first=cli('sync');assert first['state']=='current'
        assert (project/'work/loaded.txt').read_text()=='v1'
        source.write_text(code.replace('v1','v2'));os.utime(source,(stamp,stamp))
        assert cli('status',2)['state']=='sourceChanged'
        second=cli('sync');assert second['state']=='current'
        assert (project/'work/loaded.txt').read_text()=='v2'
        assert second['receipt']['proof']['pid']!=first['receipt']['proof']['pid']
        assert cli('status')['state']=='current'
        cli('stop');assert cli('status',2)['state']=='stopped'
        print('PASS: zero-config Python console script, actual project-source import/compile, independent in-process proof, v1→v2 despite stale timestamp pyc, exact stop and no configuration file')
    finally:subprocess.run([BINARY,'stop',str(project),'--target','python:sample','--json'],env=env,capture_output=True,timeout=30)
