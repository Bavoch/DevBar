"""Verify public Launch Services/launchd routes without windows or private APIs. TCC is tested separately with QuiX."""
from pathlib import Path
import json, os, plistlib, shlex, shutil, signal, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get('DEVBAR_TEST_BINARY', ROOT / '.build/release/DevBar')).resolve()

def wait(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = read()
            if value: return value
        except (OSError, ValueError, StopIteration): pass
        time.sleep(.1)
    raise AssertionError(label)

with tempfile.TemporaryDirectory(prefix='Permission ownership ', dir=ROOT / 'work') as folder:
    base = Path(folder)
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base/'state'), DEVBAR_HEADLESS='1')
    source = base/'Fixture.m'
    source.write_text(r'''
#import <AppKit/AppKit.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
 @autoreleasepool {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
  NSString *directory = [NSString stringWithUTF8String:argv[argc-1]];
  NSString *mode = argc > 2 ? [NSString stringWithUTF8String:argv[1]] : @"probe";
  NSDictionary *report = @{@"pid": @(getpid()), @"parent": @(getppid()), @"bundle": NSBundle.mainBundle.bundleIdentifier ?: @""};
  NSString *file = [directory stringByAppendingPathComponent:[mode stringByAppendingString:@".json"]];
  [[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] writeToFile:file atomically:YES];
  if ([mode isEqualToString:@"child"]) return 0;
  if ([mode isEqualToString:@"manager"]) {
   NSDictionary *job = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"job.json"]] options:0 error:nil];
   NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:job[@"executable"]]; task.arguments = job[@"arguments"];
   task.environment = job[@"environment"];
   task.standardOutput = [NSFileHandle fileHandleWithNullDevice]; task.standardError = [NSFileHandle fileHandleWithNullDevice];
   if (![task launchAndReturnError:nil]) return 96;
  } else {
   pid_t child = fork();
   if (!child) { execl(argv[0], argv[0], "child", [directory fileSystemRepresentation], NULL); _exit(97); }
   waitpid(child, NULL, 0);
  }
  [application run];
 }
}
''')
    native = base/'Fixture'
    subprocess.run(['clang','-framework','AppKit',str(source),'-o',str(native)],check=True,capture_output=True)
    def app(path, identifier):
        (path/'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(native,path/'Contents/MacOS/Fixture')
        (path/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleExecutable':'Fixture','CFBundlePackageType':'APPL','LSUIElement':True}))
        subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,capture_output=True)
        return path
    manager = app(base/'Manager.app','local.devbar.ownership.manager.'+str(os.getpid()))
    project = base/'Project with spaces';project.mkdir()
    target = app(project/'build/Fixture.app','local.devbar.ownership.target.'+str(os.getpid()))
    info = plistlib.loads((target/'Contents/Info.plist').read_bytes())
    (project/'Info.plist').write_bytes(plistlib.dumps(info))
    # Launch Services gets arguments for the bundle route via its environment;
    # the fixture uses a fixed default output path compiled into the executable.
    # For the native route use a tiny wrapper main with the same native probe.
    native_source = source.read_text().replace('NSString *directory = [NSString stringWithUTF8String:argv[argc-1]];', 'NSString *directory = argc > 1 ? [NSString stringWithUTF8String:argv[argc-1]] : @'+json.dumps(str(base/'native'))+';')
    source.write_text(native_source)
    subprocess.run(['clang','-framework','AppKit',str(source),'-o',str(target/'Contents/MacOS/Fixture')],check=True,capture_output=True)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True,capture_output=True)
    managed = []
    def cli(*args, check=True):
        return subprocess.run([str(BINARY),*args],env=env,capture_output=True,text=True,check=check,timeout=45)
    def run_manager(args, output, executable=BINARY):
        output.mkdir(exist_ok=True)
        (output/'job.json').write_text(json.dumps({'executable':str(executable),'arguments':list(args),'environment':env}))
        subprocess.run(['open','-g','-j','-n',str(manager),'--args','manager',str(output)],check=True,capture_output=True)
        report=wait(lambda: json.loads((output/'manager.json').read_text()),'manager did not start')
        managed.append(report['pid'])
        assert report['parent']==1, report
        return report
    def evidence(output, owner):
        probe=wait(lambda: json.loads((output/'probe.json').read_text()),'target did not start')
        child=wait(lambda: json.loads((output/'child.json').read_text()),'child did not report')
        managed.append(probe['pid'])
        assert probe['parent']!=owner['pid'], (probe,owner)
        assert child['parent']==probe['pid'], (child,probe)
        return probe
    try:
        # Control proves the test can detect this bug, rather than always pass.
        control=base/'control'
        parent=run_manager(['probe',str(control)],control, target/'Contents/MacOS/Fixture')
        observed=wait(lambda: json.loads((control/'probe.json').read_text()),'control did not start')
        managed.append(observed['pid'])
        assert observed['parent']==parent['pid'], (observed,parent)
        os.kill(observed['pid'],signal.SIGTERM)
        print('PASS: control detects direct execution as a child of the GUI manager')

        output=base/'command';output.mkdir()
        command=shlex.join([str(target/'Contents/MacOS/Fixture'),'probe',str(output)])
        ident=cli('--add-project',str(project),'--name','PermissionFixture','--command',command).stdout.strip()
        parent=run_manager(['--start-project',ident],output)
        probe=evidence(output,parent)
        record=json.loads((base/'state'/f'{ident}.run.json').read_text())
        live=subprocess.check_output(['ps','-p',str(record['pid']),'-o','ppid='],text=True).strip()
        assert live=='1' and record['launchID'], record
        cli('--stop-project',ident)
        print('PASS: saved command is a verified launchd job with child tracking and normal stop')

        output=base/'process';output.mkdir()
        (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'service':{'strategy':'process','startCommand':shlex.join([str(target/'Contents/MacOS/Fixture'),'probe',str(output)]),'sourcePaths':['Info.plist'],'timeout':8}}}))
        parent=run_manager(['sync',str(project),'--target','service','--json'],output)
        evidence(output,parent)
        wait(lambda: json.loads(cli('status',str(project),'--target','service','--json',check=False).stdout).get('state')=='runningUnverified', 'process receipt missing')
        stopped=cli('stop',str(project),'--target','service','--json',check=False)
        assert stopped.returncode==0, (stopped.stdout,stopped.stderr)
        print('PASS: managed process/sync uses the system job backend')

        (project/'.devbar.json').unlink()
        output=base/'native';output.mkdir()
        parent=run_manager(['--run-target',str(project),'--target','bundle'],output)
        probe=evidence(output,parent)
        session=wait(lambda: next((base/'state/targets').glob('*.json')),'bundle session missing')
        record=json.loads(session.read_text());assert record['pid']==probe['pid'] and record['bundleID']==info['CFBundleIdentifier'], record
        cli('--stop-project',ident)
        print('PASS: native bundle launches through Launch Services; exact PID/bundle and normal stop verified')

        desktop=base/'Desktop project';desktop.mkdir()
        shutil.copytree(target,desktop/'build/Fixture.app')
        (desktop/'Info.plist').write_bytes(plistlib.dumps(info))
        (desktop/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'desktop':{
            'strategy':'macBundle','buildCommand':'/usr/bin/true','artifact':'build/Fixture.app',
            'installPath':str(desktop/'work/Independent.app'),'bundleIdentifier':info['CFBundleIdentifier'],
            'sourcePaths':['Info.plist'],'timeout':30}}}))
        for name in ['probe.json','child.json']:
            (output/name).unlink(missing_ok=True)
        desktop_id=cli('--add-project',str(desktop)).stdout.strip()
        parent=run_manager(['--start-project',desktop_id],base/'desktop-manager')
        probe=evidence(output,parent)
        report=wait(lambda: (lambda v: v if v.get('state')=='current' else None)(json.loads(cli('status',str(desktop),'--target','desktop','--json',check=False).stdout)), 'desktop startup did not use macBundle')
        assert report['receipt']['pid']==probe['pid'],report
        assert report['receipt']['executable']==str(desktop/'work/Independent.app/Contents/MacOS/Fixture'),report
        cli('--stop-project',desktop_id)
        print('PASS: ordinary desktop Start automatically builds/installs/opens its independent app, without running the development command')

        symbols=subprocess.check_output(['nm','-u',str(BINARY)],text=True)
        assert 'responsibility_' not in symbols
        assert not (BINARY.parent.parent/'Helpers/DevBarLaunch').exists()
        print('PASS: product has no private responsibility API or launch helper')

    finally:
        for pid in reversed(managed):
            try: os.kill(pid,signal.SIGTERM)
            except ProcessLookupError: pass
