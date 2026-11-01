"""Verify isolated Launch Services/launchd ownership without windows or private APIs.

Actual interactive privacy permission use requires separate target-app acceptance.
"""
from pathlib import Path
import hashlib, json, os, plistlib, re, shlex, shutil, signal, subprocess, tempfile, time

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
#import <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
 @autoreleasepool {
  NSApplication *application = NSApplication.sharedApplication;
  [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
  NSString *directory = [NSString stringWithUTF8String:argv[argc-1]];
  NSString *mode = argc > 2 ? [NSString stringWithUTF8String:argv[1]] : @"probe";
  if ([mode isEqualToString:@"probe"] || [mode isEqualToString:@"child"]) CGPreflightScreenCaptureAccess();
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
    subprocess.run(['clang','-framework','AppKit','-framework','CoreGraphics',str(source),'-o',str(native)],check=True,capture_output=True)
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
    subprocess.run(['clang','-framework','AppKit','-framework','CoreGraphics',str(source),'-o',str(target/'Contents/MacOS/Fixture')],check=True,capture_output=True)
    subprocess.run(['codesign','--force','--sign','-',str(target)],check=True,capture_output=True)
    managed = []
    saved_ids = []
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
        # Checking only the GUI manager's immediate parent missed a DevBar CLI
        # supervisor between that manager and the actual development command.
        rows = {}
        for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines():
            fields=line.strip().split(None,2)
            if len(fields)==3: rows[int(fields[0])] = (int(fields[1]), fields[2])
        pid=probe['pid']
        while pid in rows and pid != 1:
            parent, executable=rows[pid]
            assert Path(executable).name != 'DevBar' and pid != owner['pid'], (pid,executable,probe)
            pid=parent
        assert pid == 1, ('Incomplete ancestor chain',probe)
        return probe

    def tcc_evidence(probe):
        # Preflight only: no permission prompt, screen capture or TCC reset.
        pid=probe['pid']
        predicate=f'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "pid={pid}"'
        def attribution():
            result=subprocess.run(['/usr/bin/log','show','--last','3m','--style','compact',
                '--info','--debug','--predicate',predicate],capture_output=True,text=True,check=True,timeout=20)
            for line in result.stdout.splitlines():
                if 'Handling access request to kTCCServiceScreenCapture,' in line and f'pid={pid},' in line:
                    return line
        line=wait(attribution,'TCC attribution for development command unavailable',timeout=30)
        responsible=re.search(r'Resp:\{([^}]+)\}',line)
        assert responsible, line
        assert f'pid={pid},' in responsible[1], line
        assert f'binary_path={project / "tool"}' in responsible[1], line
        print('PASS: real ScreenCapture preflight TCC responsible identity is the development target, not DevBar')
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
        # 面板与开发会话拒绝把安装包当开发命令；用 .app 外的同一二进制副本走受管启动。
        tool=project/'tool'; shutil.copy2(native,tool); os.chmod(tool,0o700)
        command=shlex.join([str(tool),'probe',str(output)])
        ident=cli('--add-project',str(project),'--name','PermissionFixture','--command',command).stdout.strip()
        saved_ids.append(ident)
        parent=run_manager(['--start-project',ident],output)
        probe=evidence(output,parent)
        tcc_evidence(probe)
        record=wait(lambda: next((json.loads(file.read_text()) for file in (base/'state').glob(f'{ident}.target-*.run.json') if json.loads(file.read_text()).get('exitCode') is None), None), 'managed target record missing')
        live=subprocess.check_output(['ps','-p',str(record['pid']),'-o','ppid='],text=True).strip()
        assert live=='1' and record['launchID'], record
        cli('--stop-project',ident)
        print('PASS: saved command is a verified launchd job with child tracking and normal stop')

        output=base/'process';output.mkdir()
        (project/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'service':{'strategy':'process','startCommand':shlex.join([str(tool),'probe',str(output)]),'sourcePaths':['Info.plist'],'timeout':8}}}))
        parent=run_manager(['sync',str(project),'--target','service','--json'],output)
        evidence(output,parent)
        wait(lambda: json.loads(cli('status',str(project),'--target','service','--json',check=False).stdout).get('state')=='current', 'development session missing')
        stopped=cli('stop',str(project),'--target','service','--json',check=False)
        assert stopped.returncode==0, (stopped.stdout,stopped.stderr)
        print('PASS: managed process/sync uses the system job backend')

        (project/'.devbar.json').unlink()
        output=base/'native';output.mkdir()
        desktop=base/'Desktop project';desktop.mkdir()
        shutil.copytree(target,desktop/'build/Fixture.app')
        (desktop/'Info.plist').write_bytes(plistlib.dumps(info))
        installed=desktop/'work/Independent.app'
        (desktop/'.devbar.json').write_text(json.dumps({'schemaVersion':1,'targets':{'desktop':{
            'strategy':'macBundle','buildCommand':'/usr/bin/touch SYNC_BUILD_RAN','artifact':'build/Fixture.app',
            'installPath':str(installed),'bundleIdentifier':info['CFBundleIdentifier'],
            'sourcePaths':['Info.plist'],'timeout':30}}}))
        ordinary=base/'ordinary';ordinary.mkdir()
        desktop_id=cli('--add-project',str(desktop),'--command',shlex.join([str(tool),'probe',str(ordinary)])).stdout.strip()
        saved_ids.append(desktop_id)
        parent=run_manager(['--start-project',desktop_id],base/'ordinary-manager')
        evidence(ordinary,parent)
        assert not installed.exists() and not (desktop/'SYNC_BUILD_RAN').exists()
        cli('--stop-project',desktop_id)
        print('PASS: ordinary Start honors the saved command and never invokes configured macBundle installation')

        # A prebuilt bundle without a source build/watch path must fail visibly;
        # its existence is not enough to make it a development session.
        cli('--select-target',desktop_id,'--target','bundle')
        rejected=cli('--start-project',desktop_id,check=False)
        assert rejected.returncode != 0 and 'dev/watch' in rejected.stderr, (rejected.stdout,rejected.stderr)
        assert not installed.exists() and not (desktop/'SYNC_BUILD_RAN').exists()
        cli('--stop-project',desktop_id)
        print('PASS: bundle-only target cannot masquerade as a development session')

        parent=run_manager(['sync',str(desktop),'--target','desktop','--json'],base/'sync-manager')
        probe=evidence(output,parent)
        assert probe['bundle']==info['CFBundleIdentifier'],probe
        report=wait(lambda: (lambda value: value if value.get('state')=='current' else None)(json.loads(cli('status',str(desktop),'--target','desktop','--json',check=False).stdout)), 'explicit macBundle sync did not complete')
        assert report['receipt']['pid']==probe['pid'],report
        assert report['receipt']['executable']==str(installed/'Contents/MacOS/Fixture'),report
        assert (desktop/'SYNC_BUILD_RAN').exists()
        os.kill(probe['pid'],signal.SIGTERM)
        wait(lambda: subprocess.run(['ps','-p',str(probe['pid']),'-o','stat='],capture_output=True,text=True).stdout.strip() in ('', 'Z'), 'native fixture did not exit')
        print('PASS: explicit macBundle sync uses Launch Services with exact PID, bundle identity and installed executable')

        symbols=subprocess.check_output(['nm','-u',str(BINARY)],text=True)
        assert 'responsibility_' not in symbols
        assert not (BINARY.parent.parent/'Helpers/DevBarLaunch').exists()
        print('PASS: product has no private responsibility API or launch helper')

    finally:
        for ident in saved_ids:
            subprocess.run([str(BINARY),'--stop-project',ident],env=env,capture_output=True,timeout=30)
        for pid in reversed(managed):
            try: os.kill(pid,signal.SIGTERM)
            except ProcessLookupError: pass
