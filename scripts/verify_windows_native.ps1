$ErrorActionPreference='Stop'
. "$PSScriptRoot/../drivers/windows.ps1"
$root=Join-Path $env:RUNNER_TEMP ('DevBar 中文 '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$source=@'
using System; using System.Net; using System.Net.Sockets; using System.Text; using System.IO; using System.Diagnostics;
class Fixture {
 static void Main(){
 string revision=File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"revision.txt")).Trim();
 string sync=Environment.GetEnvironmentVariable("DEVBAR_SYNC_ID");string target=Environment.GetEnvironmentVariable("DEVBAR_SYNC_TARGET");string instance=Guid.NewGuid().ToString();
 var h=new TcpListener(IPAddress.Loopback,38765);h.Start();
 while(true){var c=h.AcceptTcpClient();var stream=c.GetStream();var reader=new StreamReader(stream);while(!String.IsNullOrEmpty(reader.ReadLine())){}string body="{\"sourceDigest\":\""+revision+"\",\"syncID\":\""+sync+"\",\"target\":\""+target+"\",\"instanceID\":\""+instance+"\",\"pid\":"+Process.GetCurrentProcess().Id+"}";var b=Encoding.UTF8.GetBytes(body);var header=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "+b.Length+"\r\nConnection: close\r\n\r\n");stream.Write(header,0,header.Length);stream.Write(b,0,b.Length);c.Close();}
 }
}
'@
$stage=Join-Path $root 'build';New-Item -ItemType Directory -Path $stage|Out-Null
$code=Join-Path $root 'fixture.cs';[IO.File]::WriteAllText($code,$source)
$csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $csc /nologo /target:winexe "/out:$stage/Fixture.exe" $code
if($LASTEXITCODE){throw 'C# fixture compilation failed'}
$config=@{installPath=(Join-Path $root 'installed');remoteArtifact=$stage;executable='Fixture.exe';proofURL='http://127.0.0.1:38765/'}
function Call-Driver($Action,$Revision='v1'){
 $body=@{action=$Action;configuration=$config;artifactDigest=(Get-DevBarTreeHash $stage);proof=@{sourceDigest=$Revision;syncID=('sync-'+$Revision);target='windows'}}|ConvertTo-Json -Depth 10 -Compress
 Invoke-DevBar ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body)))
}
$results=@()
try{
 [IO.File]::WriteAllText((Join-Path $stage 'revision.txt'),'v1')
 [IO.File]::WriteAllText((Join-Path $stage '中文 asset.txt'),'unicode filename')
 [IO.File]::WriteAllText((Join-Path $stage '.metadata'),'hidden metadata')
 $v1=Call-Driver 'sync';if($v1.sourceDigest -ne 'v1'){throw 'v1 not running'}
 $status=Call-Driver 'status';if($status.instanceID -ne $v1.instanceID){throw 'read only status changed instance'}
 $results+=@{test='v1 actual process + read only proof';passed=$true;pid=$v1.pid}
 [IO.File]::WriteAllText((Join-Path $stage 'revision.txt'),'v2')
 $v2=Call-Driver 'sync' 'v2';if($v2.sourceDigest -ne 'v2' -or $v2.instanceID -eq $v1.instanceID){throw 'v2 update failed'}
 if(Get-Process -Id $v1.pid -ErrorAction SilentlyContinue){throw 'old process survived'}
 $results+=@{test='v1 to v2 atomic install and new runtime';passed=$true;pid=$v2.pid}
 $installedRevision=Join-Path $config.installPath 'revision.txt'
 [IO.File]::WriteAllText($installedRevision,'tampered')
 $failed=$false;try{Call-Driver 'status'|Out-Null}catch{$failed=$true};if(!$failed){throw 'tampered artifact accepted'}
 [IO.File]::WriteAllText($installedRevision,'v2')
 $results+=@{test='installed content tampering rejected';passed=$true}
 Call-Driver 'stop'|Out-Null
 $failed=$false;try{Call-Driver 'status'|Out-Null}catch{$failed=$true};if(!$failed){throw 'stopped runtime accepted'}
 $results+=@{test='exact process stop and stale receipt rejected';passed=$true}
 $evidence=@{platform=[Environment]::OSVersion.VersionString;architecture=$env:PROCESSOR_ARCHITECTURE;tests=$results;passed=$true}
 $evidence|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $pwd 'windows-native-evidence.json')
 $evidence|ConvertTo-Json -Depth 10
}finally{
 Get-Process Fixture -ErrorAction SilentlyContinue|Where-Object{$_.Path -and $_.Path.StartsWith($root)}|Stop-Process -ErrorAction SilentlyContinue
}
