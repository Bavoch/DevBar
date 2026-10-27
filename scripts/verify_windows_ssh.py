from pathlib import Path
import importlib.util,json,os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native',ROOT/'drivers/native.py');native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
# Reuse the exact C# app fixture and native updater test to produce an artifact.
source=(ROOT/'scripts/verify_windows_native.ps1').read_text()
# Its final output proves native gates; the root is read from a temporary instrumentation line.
source=source.replace("$source=@'", "Set-Content -LiteralPath (Join-Path $pwd 'windows-fixture-root.txt') -Value $root -Encoding utf8\n$source=@'")
script=ROOT/'work-windows-fixture.ps1';script.write_text(source,encoding='utf-8-sig')
# Preserve relative PSScriptRoot references after moving this scratch file to scripts.
script=ROOT/'scripts/work-windows-fixture.ps1';script.write_text(source,encoding='utf-8-sig')
subprocess.run(['pwsh.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(script)],check=True)
fixture=Path((ROOT/'windows-fixture-root.txt').read_text(encoding='utf-8-sig').strip())
artifact=fixture/'build';stage=fixture/'transfer';stage.mkdir()
config={'strategy':'windowsSSH','host':'devbar-windows-ci','remoteStage':stage.as_posix(),'remoteArtifact':str(stage),'installPath':str(fixture/'ssh-installed'),'executable':'Fixture.exe','proofURL':'http://127.0.0.1:38765/','artifact':str(artifact)}
proof={'sourceDigest':'v2','syncID':'ssh-v2','target':'windows'}
name='devbar-'+__import__('uuid').uuid4().hex
remote={**config,'remoteArtifact':str(stage/name)}
# Bound every remote call so a hang surfaces as a fast, readable CI failure.
native.windows(remote,'prepare',timeout=45)
try:
 native.run(['scp','-q','-r',str(artifact)+'/.','devbar-windows-ci:'+stage.as_posix()+'/'+name+'/'],timeout=60)
 first=native.windows(remote,'sync',proof,native.portable_tree(artifact))
 second=native.windows(config,'status')
 assert first['sourceDigest']=='v2' and first['instanceID']==second['instanceID']
 native.windows(config,'stop')
 evidence={'passed':True,'transport':'real OpenSSH public key + SFTP','platform':'Windows','proof':second,'hostKeyVerification':True}
 config={**config,'launchMode':'interactive','installPath':str(fixture/'interactive-installed')}
 interactive={**remote,**config,'remoteArtifact':remote['remoteArtifact']}
 value=native.windows(interactive,'sync',{'sourceDigest':'v2','syncID':'interactive-v2','target':'windows'},native.portable_tree(artifact))
 checked=native.windows(config,'status')
 assert checked['sessionID']>0 and checked['deviceKind']=='interactiveWindowsSession' and value['instanceID']==checked['instanceID']
 native.windows(config,'stop')
 evidence['interactive']=checked
 (ROOT/'windows-ssh-evidence.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
finally:native.windows(remote,'cleanStage',timeout=45)
