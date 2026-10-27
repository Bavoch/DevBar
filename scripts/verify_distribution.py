"""Verify the relocated shipped App/CLI works without access to its source checkout."""
from pathlib import Path
import json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='Relocated product ',dir=ROOT/'work') as folder:
    base=Path(folder);app=base/'DevBar Product.app'
    shutil.copytree(ROOT/'dist/DevBar.app',app,symlinks=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    assert not (app/'Contents/Helpers/DevBarLaunch').exists()
    symbols=subprocess.check_output(['nm','-u',str(app/'Contents/MacOS/DevBar')],text=True)
    assert 'responsibility_' not in symbols
    wrapper=app/'Contents/Resources/devbar'
    assert 'doctor' in subprocess.check_output([str(wrapper),'--help'],text=True)
    import plistlib
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    version=subprocess.check_output([str(wrapper),'--version'],text=True).strip()
    assert version == f"DevBar {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})",version
    for document in ('README.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md'):
        assert (app/'Contents/Resources'/document).is_file(), document
    project=base/'Independent project';project.mkdir()
    (project/'package.json').write_text(json.dumps({'scripts':{'dev':'python3 -m http.server 0 --bind 127.0.0.1'}}))
    env=dict(os.environ,DEVBAR_CLI_DIR=str(base/'bin'),DEVBAR_DATA_DIR=str(base/'state'))
    subprocess.run(['zsh',str(app/'Contents/Resources/install-cli.sh')],env=env,check=True,capture_output=True)
    cli=base/'bin/devbar'
    assert cli.is_symlink() and str(app) in str(cli.resolve())
    def command(*args,code=0):
        r=subprocess.run([str(cli),*args],env=env,cwd=base,capture_output=True,text=True,timeout=30)
        assert r.returncode==code,(r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout)
    assert command('doctor',str(project))['role']=='application'
    assert command('init',str(project),'--plan')['state']=='planned'
    assert not (project/'.devbar.json').exists()
    assert command('init',str(project),'--write')['state']=='configured'
    content=(project/'.devbar.json').read_bytes()
    assert (project/'.devbar.json').stat().st_mode&0o777==0o600
    assert command('init',str(project),'--write',code=1)['state']=='setupRequired'
    assert (project/'.devbar.json').read_bytes()==content
    binary=app/'Contents/MacOS/DevBar'
    r=subprocess.run([str(binary),'invalid-command'],capture_output=True,text=True,timeout=5)
    assert r.returncode==1 and json.loads(r.stdout)['state']=='setupRequired'
    print('PASS: relocated signed App CLI, independent cwd, bundled installer, no source dependency, doctor, read-only draft, exclusive configuration creation, invalid commands fail without launching GUI')
