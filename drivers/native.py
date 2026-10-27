#!/usr/bin/env python3
"""Built-in device/host transports. Proof is read from the running target, never env echo."""
import base64, gzip, hashlib, json, os, pathlib, plistlib, re, shutil, signal, subprocess, sys, tempfile, time, urllib.request, uuid
sys.dont_write_bytecode = True

def run(args, **kw):
    p = subprocess.run(args, capture_output=True, text=True, timeout=kw.pop("timeout",60), **kw)
    if p.returncode: raise RuntimeError((p.stderr or p.stdout)[-5000:])
    return p.stdout.strip()
def read(path): return json.loads(pathlib.Path(path).read_text())
def write(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix('.tmp'); tmp.write_text(json.dumps(value)); tmp.chmod(0o600); tmp.replace(path)
def sha(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def executable(name, fallback=None):
    p = shutil.which(name) or (fallback if fallback and pathlib.Path(fallback).is_file() else None)
    if not p: raise RuntimeError('Missing executable: '+name)
    return p
def device_json(args):
    with tempfile.TemporaryDirectory() as d:
        path=d+'/result.json'; run(['/usr/bin/xcrun','devicectl']+args+['--timeout','30','--json-output',path]); return read(path)['result']
def adb(c, *args):
    sdk=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or str(pathlib.Path.home()/'Library/Android/sdk')
    tool=executable('adb',sdk+'/platform-tools/adb')
    return run([tool,'-s',c['device']]+list(args))
def request(state):
    req=urllib.request.Request(state['url'],headers={'Authorization':'Bearer '+state['token']})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=4) as r: return json.load(r)
def stop_host(state):
    # The target must answer its private nonce before its exact PID is signalled.
    p=request(state)
    if p['instanceID'] != state['instanceID']: raise RuntimeError('Host instance changed')
    os.kill(p['pid'],signal.SIGTERM)
    for _ in range(100):
        try: os.kill(p['pid'],0)
        except ProcessLookupError: return
        time.sleep(.05)
    raise RuntimeError('Host did not exit after SIGTERM; no unrelated process was killed')
def portable_tree(path):
    rows=[]
    for p in pathlib.Path(path).rglob('*'):
        if p.is_symlink(): raise RuntimeError('Windows artifact contains symlinks')
        if p.is_file(): rows.append('/'+p.relative_to(path).as_posix()+':'+sha(p))
    if not rows: raise RuntimeError('Empty Windows artifact')
    return hashlib.sha256('\n'.join(sorted(rows,key=lambda row:row.encode('utf-16be'))).encode()).hexdigest()
def windows(c, action, payload=None, digest=None, timeout=None):
    host=c['host']
    if host.startswith('-') or any(x.isspace() for x in host): raise RuntimeError('Invalid SSH host alias')
    agent=pathlib.Path(__file__).with_name('windows.ps1').read_text()
    data=base64.b64encode(json.dumps({'action':action,'configuration':c,'proof':payload,**({'artifactDigest':digest} if digest else {})}).encode()).decode()
    script=agent+'\nInvoke-DevBar -PayloadBase64 '+repr(data)+' | ConvertTo-Json -Depth 15 -Compress'
    # Compress the trusted bundled agent into an ASCII-only command. Windows
    # OpenSSH console stdin does not reliably forward EOF to nested PowerShell.
    packed=base64.b64encode(gzip.compress(script.encode())).decode()
    loader="$b=[Convert]::FromBase64String('"+packed+"');$m=[IO.MemoryStream]::new($b);$g=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);$r=[IO.StreamReader]::new($g,[Text.Encoding]::UTF8);& ([ScriptBlock]::Create($r.ReadToEnd()))"
    command='powershell.exe -NoProfile -NonInteractive -Command "'+loader+'"'
    if len(command)>7800: raise RuntimeError('Windows SSH payload exceeds the supported command length; shorten target paths/configuration')
    return json.loads(run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10',host,command],timeout=timeout or min(c.get('timeout',120),120)))

def main():
    action=sys.argv[1]; cfg=read(sys.argv[2]); c=cfg['configuration']; strategy=c['strategy']
    path=pathlib.Path(cfg['state']); old=read(path) if path.exists() else None
    root=pathlib.Path(cfg['project']).resolve()
    artifact=(root/c.get('artifact','')).resolve()
    proof={k:os.environ[v] for k,v in [('sourceDigest','DEVBAR_SOURCE_DIGEST'),('syncID','DEVBAR_SYNC_ID'),('target','DEVBAR_SYNC_TARGET')] if v in os.environ}
    if strategy=='dockerCompose':
        from docker_driver import handle
        print(json.dumps(handle(action,c,root,path,proof))); return
    if strategy=='windowsSSH':
        if action=='sync':
            stage=c['remoteStage']
            if any(x in stage for x in ['"',"'",'\n']): raise RuntimeError('Invalid remoteStage')
            original=dict(c); name='devbar-'+uuid.uuid4().hex
            c={**c,'remoteArtifact':c['remoteArtifact'].rstrip('\\/')+'\\'+name}
            windows(c,'prepare')
            try:
                run(['scp','-q','-r',str(artifact)+'/.',c['host']+':'+stage.rstrip('/')+'/'+name+'/'])
                value=windows(c,action,proof,portable_tree(artifact))
            finally: windows(c,'cleanStage')
        else: value=windows(c,action,proof)
        print(json.dumps(value)); return
    if action=='stop':
        if not old: raise RuntimeError('No managed native session')
        if strategy in ('blender','omp','dsh'): stop_host(old)
        elif strategy=='androidDevice':
            current_proof=json.loads(run([sys.executable,__file__,'status',sys.argv[2]]))
            if current_proof.get('instanceID')!=old.get('proof',{}).get('instanceID'): raise RuntimeError('Android runtime instance changed')
            current=adb(c,'shell','pidof',c['bundleIdentifier'])
            if current!=str(old['pid']): raise RuntimeError('Android process changed')
            adb(c,'shell','am','force-stop',c['bundleIdentifier'])
        else:
            current_proof=json.loads(run([sys.executable,__file__,'status',sys.argv[2]]))
            if current_proof.get('instanceID')!=old.get('proof',{}).get('instanceID'): raise RuntimeError('iOS runtime instance changed')
            live=device_json(['device','info','processes','--device',c['device']])
            if not any(p.get('processIdentifier')==old['pid'] for p in live.get('runningProcesses',[])): raise RuntimeError('iOS process changed')
            device_json(['device','process','terminate','--device',c['device'],'--pid',str(old['pid'])])
        print('{}'); return
    if strategy in ('blender','omp','dsh'):
        if action=='sync':
            if old:
                try: stop_host(old)
                except (OSError,RuntimeError):
                    # Dead hosts may be replaced; a live unverified host is never killed.
                    try: os.kill(old['pid'],0)
                    except ProcessLookupError: pass
                    else: raise
            token=uuid.uuid4().hex; instance=uuid.uuid4().hex
            entry=(root/c['entry']).resolve()
            if not entry.is_relative_to(root) or not entry.is_file(): raise RuntimeError('entry must be a project file')
            boot={**proof,'instanceID':instance,'token':token,'entry':str(entry),'artifactDigest':sha(entry),'state':str(path),'strategy':strategy,'configuration':c}
            bootpath=str(path)+'.boot.json'; write(bootpath,boot)
            log=open(str(path)+'.log','a'); os.chmod(str(path)+'.log',0o600)
            worker=pathlib.Path(__file__).with_name('host.py')
            child=subprocess.Popen([sys.executable,"-B",str(worker),bootpath,c.get('hostExecutable','')],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True,close_fds=True)
            deadline=time.monotonic()+min(60,c.get("timeout",120)-5)
            while time.monotonic()<deadline:
                try:
                    state=read(path)
                    if state['instanceID']==instance:
                        value=request(state)
                        if value['artifactDigest']!=sha(entry): raise RuntimeError('Loaded code changed during startup')
                        print(json.dumps(value)); return
                except (OSError,ValueError,RuntimeError): pass
                time.sleep(.2)
            try: os.killpg(child.pid,signal.SIGTERM)
            except ProcessLookupError: pass
            raise RuntimeError('Host failed to load entry; see '+str(path)+'.log')
        if not old: raise RuntimeError('No host session')
        value=request(old)
        if value['instanceID']!=old['instanceID'] or value['artifactDigest']!=sha(root/c['entry']): raise RuntimeError('Host code or instance changed')
    elif strategy=='androidDevice':
        package=c['bundleIdentifier']
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.]*',package) or not re.fullmatch(r'[A-Za-z0-9_.$]+',c['activity']): raise RuntimeError('Invalid Android package/activity')
        proof_file=c.get('runtimeProofPath','files/devbar-runtime.json')
        if not re.fullmatch(r'files/[A-Za-z0-9_./-]+',proof_file) or '..' in proof_file.split('/'): raise RuntimeError('runtimeProofPath must be under files/')
        if action=='sync':
            if adb(c,'get-state')!='device': raise RuntimeError('Android device unavailable/unauthorized')
            adb(c,'install','-r',str(artifact))
            adb(c,'shell','am','force-stop',package)
            # Runtime SDK must read bundled revision, not merely this launch nonce.
            adb(c,'shell','am','start','-W','-n',package+'/'+c['activity'],'--es','devbarSyncID',proof['syncID'],'--es','devbarTarget',proof['target'])
        pid=adb(c,'shell','pidof',package)
        if not pid or ' ' in pid: raise RuntimeError('Expected one Android main process')
        value=json.loads(adb(c,'shell','run-as',package,'cat',proof_file))
        if str(value.get('pid'))!=pid: raise RuntimeError('Android proof not written by running process')
        installed=adb(c,'shell','pm','path',package).splitlines()
        if len(installed)!=1: raise RuntimeError('Split APKs require a dedicated split install configuration')
        remote=installed[0].removeprefix('package:')
        with tempfile.TemporaryDirectory() as d:
            adb(c,'pull',remote,d+'/installed.apk')
            if sha(d+'/installed.apk')!=sha(artifact): raise RuntimeError('Installed APK differs from built APK')
        value['instanceID']=c['device']+':'+pid+':'+value['instanceID']
        value.update(platform='Android',deviceKind='emulator' if adb(c,'shell','getprop','ro.kernel.qemu')=='1' else 'physical',artifactDigest=sha(artifact))
        if action=='sync': write(path,{'pid':int(pid),'proof':value})
    elif strategy=='iosDevice':
        devices=device_json(['list','devices']).get('devices',[])
        device=next((d for d in devices if c['device'] in [d.get('identifier'),d.get('hardwareProperties',{}).get('udid'),d.get('deviceProperties',{}).get('name')]),None)
        if not device or device.get('connectionProperties',{}).get('tunnelState')=='unavailable': raise RuntimeError('Physical iOS device offline: connect, unlock and trust this Mac')
        package=c['bundleIdentifier']; runtime=c.get('runtimeProofPath','Library/Caches/devbar-runtime.json')
        if runtime.startswith('/') or '..' in runtime.split('/'): raise RuntimeError('Invalid runtimeProofPath')
        if action=='sync':
            info=plistlib.loads((artifact/'Info.plist').read_bytes())
            if info['CFBundleIdentifier']!=package: raise RuntimeError('Built bundle identifier mismatch')
            device_json(['device','install','app','--device',c['device'],str(artifact)])
            result=device_json(['device','process','launch','--device',c['device'],'--terminate-existing','--environment-variables',json.dumps({'DEVBAR_SYNC_ID':proof['syncID'],'DEVBAR_SYNC_TARGET':proof['target']}),package])
            pid=result['process']['processIdentifier']
            write(path,{'pid':pid})
            old=read(path)
        if not old: raise RuntimeError('No device session')
        live=device_json(['device','info','processes','--device',c['device']])
        if not any(p.get('processIdentifier')==old['pid'] for p in live.get('runningProcesses',[])): raise RuntimeError('iOS process is no longer running')
        with tempfile.TemporaryDirectory() as d:
            device_json(['device','copy','from','--device',c['device'],'--domain-type','appDataContainer','--domain-identifier',package,'--source',runtime,'--destination',d+'/proof.json'])
            value=read(d+'/proof.json')
        if value.get('pid')!=old['pid']: raise RuntimeError('iOS runtime proof has a stale PID')
        executable_name=plistlib.loads((artifact/'Info.plist').read_bytes())['CFBundleExecutable']
        if value.get('executableDigest')!=sha(artifact/executable_name): raise RuntimeError('iOS executable digest mismatch')
        value['instanceID']=c['device']+':'+str(old['pid'])+':'+value['instanceID']
        value.update(platform='iOS',deviceKind='physical')
        if action=='sync': write(path,{'pid':old['pid'],'proof':value})
    else: raise RuntimeError('Unknown built-in driver')
    print(json.dumps(value))
if __name__=='__main__':
    try: main()
    except Exception as e: print(str(e),file=sys.stderr); sys.exit(1)
