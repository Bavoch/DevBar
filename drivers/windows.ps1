# Native Windows updater. Caller supplies a staged directory on the Windows host.
# No browser windows are launched by this driver. GUI applications own their UI policy.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-DevBarFileHash([string]$Path) {
    $stream=[IO.File]::OpenRead($Path); $hash=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose(); $hash.Dispose() }
}
function Remove-DevBarTask($Receipt) {
    if ($Receipt -and $Receipt.PSObject.Properties.Name -contains 'taskName' -and $Receipt.taskName) {
        if ($Receipt.taskName -notmatch '^DevBar-[a-f0-9]{32}$') { throw 'Invalid owned Windows task identity' }
        $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect()
        try {$scheduler.GetFolder('\').DeleteTask($Receipt.taskName,0)}catch{if($_.Exception.HResult -ne -2147024894){throw}}
    }
}
function Get-DevBarTreeHash([string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Artifact contains a reparse point' }
    [string[]]$rows = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Artifact contains a reparse point' }
        $_.FullName.Substring($rootPath.Length).Replace('\','/') + ':' + (Get-DevBarFileHash $_.FullName)
    })
    [Array]::Sort($rows, [StringComparer]::Ordinal)
    if (!$rows.Count) { throw 'Empty artifact' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-DevBarProcess($Receipt) {
    $p = Get-Process -Id $Receipt.pid -ErrorAction SilentlyContinue
    if (!$p -or $p.StartTime.ToUniversalTime().Ticks.ToString() -ne $Receipt.started -or [IO.Path]::GetFullPath($p.Path) -ne $Receipt.executable) { throw 'Running Windows process identity changed' }
    return $p
}
function Get-DevBarEvidence($Config, $Receipt) {
    $p = Get-DevBarProcess $Receipt
    if ((Get-DevBarTreeHash $Config.installPath) -ne $Receipt.artifactDigest) { throw 'Installed Windows artifact changed' }
    $u = [Uri]$Config.proofURL
    if (!$u.IsLoopback -or $u.UserInfo -or $u.Scheme -ne 'http') { throw 'proofURL must use loopback HTTP' }
    $value = Invoke-RestMethod -Uri $u.AbsoluteUri -TimeoutSec 4 -MaximumRedirection 0
    foreach ($k in @('sourceDigest','syncID','target')) { if ($value.$k -ne $Receipt.proof.$k) { throw "Windows runtime $k mismatch" } }
    if ($value.pid -ne $p.Id -or !$value.instanceID) { throw 'Windows runtime PID/instance mismatch' }
    if ($Receipt.PSObject.Properties.Name -contains 'instanceID') {
        if ($value.instanceID -ne $Receipt.instanceID) { throw 'Windows runtime instance changed' }
    }
    $value | Add-Member -NotePropertyName platform -NotePropertyValue 'Windows' -Force
    $mode=if($Receipt.PSObject.Properties.Name -contains 'launchMode'){$Receipt.launchMode}else{'background'}
    if($mode -eq 'interactive' -and $p.SessionId -le 0){throw 'Windows application is not in an interactive user session'}
    $kind=if($mode -eq 'interactive'){'interactiveWindowsSession'}else{'detachedWindowsSession'}
    $value | Add-Member -NotePropertyName deviceKind -NotePropertyValue $kind -Force
    $value | Add-Member -NotePropertyName sessionID -NotePropertyValue $p.SessionId -Force
    return $value
}
function Invoke-DevBar([string]$PayloadBase64) {
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64)) | ConvertFrom-Json
    $c=$request.configuration
    $mode=if($c.PSObject.Properties.Name -contains 'launchMode'){$c.launchMode}else{'background'}
    if($mode -notin @('interactive','background')){throw 'Invalid Windows launchMode'}
    $dest=[IO.Path]::GetFullPath($c.installPath)
    $stage=[IO.Path]::GetFullPath($c.remoteArtifact)
    if ($dest -eq [IO.Path]::GetPathRoot($dest) -or $dest -eq $stage -or $stage.StartsWith($dest+'\') -or $dest.StartsWith($stage+'\')) { throw 'Stage and install directories must be independent' }
    if ([IO.Path]::IsPathRooted($c.executable) -or ($c.executable -split '[\\/]') -contains '..') { throw 'executable must be a relative path' }
    if ($request.action -eq 'prepare' -or $request.action -eq 'cleanStage') {
        if ([IO.Path]::GetFileName($stage) -notmatch '^devbar-[0-9a-f]{32}$') { throw 'Invalid owned stage directory' }
        if ($request.action -eq 'prepare') { [IO.Directory]::CreateDirectory($stage) | Out-Null }
        elseif (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        return @{}
    }
    $receiptPath=$dest+'.devbar-receipt.json'; $lockPath=$dest+'.devbar-lock'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
    $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
    try {
        $old=if(Test-Path -LiteralPath $receiptPath){Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json}else{$null}
        if ($request.action -eq 'status') {
            if (!$old) { throw 'No Windows runtime receipt' }
            return Get-DevBarEvidence $c $old
        }
        if ($request.action -eq 'stop') {
            if (!$old) { throw 'No Windows runtime receipt' }
            $p=Get-DevBarProcess $old; Stop-Process -Id $p.Id; Remove-DevBarTask $old; return @{}
        }
        if ($request.action -ne 'sync') { throw 'Unknown action' }
        $digest=Get-DevBarTreeHash $stage
        if ($request.PSObject.Properties.Name -contains 'artifactDigest') { if ($digest -ne $request.artifactDigest) { throw 'Transferred Windows artifact differs from local source bytes' } }
        $new=$dest+'.stage-'+[Guid]::NewGuid().ToString('N'); $backup=$dest+'.backup-'+[Guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $stage -Destination $new -Recurse -Force
        if ((Get-DevBarTreeHash $new) -ne $digest) { throw 'Staged artifact verification failed' }
        $candidate=Join-Path $new $c.executable
        if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Missing executable' }
        # Only a recorded exact PID + creation time + executable may be stopped.
        if ($old) {
            $p=Get-Process -Id $old.pid -ErrorAction SilentlyContinue
            if ($p) { $p=Get-DevBarProcess $old; Stop-Process -Id $p.Id; $p.WaitForExit(10000) | Out-Null }; Remove-DevBarTask $old
        }
        $moved=$false; $installed=$false; $process=$null; $taskName=$null
        try {
            if(Test-Path -LiteralPath $dest){Move-Item -LiteralPath $dest -Destination $backup; $moved=$true}
            Move-Item -LiteralPath $new -Destination $dest; $installed=$true
            $exe=[IO.Path]::GetFullPath((Join-Path $dest $c.executable))
            # WMI creates the bootstrap outside the OpenSSH session job. Otherwise
            # SSH disconnect kills a successful Start-Process child immediately.
            $pidFile=$receiptPath+'.launch-'+[Guid]::NewGuid().ToString('N')+'.json'
            $launch=@{executable=$exe;directory=$dest;pidFile=$pidFile;wait=($mode -eq 'interactive');environment=@{DEVBAR_SOURCE_DIGEST=$request.proof.sourceDigest;DEVBAR_SYNC_ID=$request.proof.syncID;DEVBAR_SYNC_TARGET=$request.proof.target;DEVBAR_HEADLESS='1'}}
            $launchData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($launch|ConvertTo-Json -Depth 10 -Compress)))
            $bootstrap=@'
$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PAYLOAD'))|ConvertFrom-Json
try {
 foreach($property in $c.environment.PSObject.Properties){[Environment]::SetEnvironmentVariable($property.Name,[string]$property.Value,'Process')}
 $p=Start-Process -FilePath $c.executable -WorkingDirectory $c.directory -PassThru
 @{pid=$p.Id}|ConvertTo-Json -Compress|Set-Content -LiteralPath $c.pidFile -Encoding utf8
 if($c.wait){$p.WaitForExit()}
} catch { @{error=$_.Exception.Message}|ConvertTo-Json -Compress|Set-Content -LiteralPath $c.pidFile -Encoding utf8; exit 1 }
'@
            $bootstrap=$bootstrap.Replace('PAYLOAD',$launchData)
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
            if($mode -eq 'interactive') {
                $scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect()
                $definition=$scheduler.NewTask(0);$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
                $definition.Principal.UserId=$user;$definition.Principal.LogonType=3;$definition.Principal.RunLevel=0
                $definition.Settings.Enabled=$true;$definition.Settings.Hidden=$true;$definition.Settings.ExecutionTimeLimit='PT0S'
                $definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false
                $action=$definition.Actions.Create(0);$action.Path=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
                $action.Arguments='-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded;$action.WorkingDirectory=$dest
                $taskName='DevBar-'+[Guid]::NewGuid().ToString('N')
                $registered=$scheduler.GetFolder('\').RegisterTaskDefinition($taskName,$definition,6,$user,$null,3)
                $registered.Run($null)|Out-Null
            } else {
                $created=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded);CurrentDirectory=$dest}
                if($created.ReturnValue -ne 0){throw ('Detached Windows launch failed: '+$created.ReturnValue)}
            }
            try {
                $deadline=[DateTime]::UtcNow.AddSeconds(20)
                while(!(Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
                if(!(Test-Path -LiteralPath $pidFile)){throw 'Detached Windows launch did not return its PID'}
                $launched=Get-Content -LiteralPath $pidFile -Raw|ConvertFrom-Json
                if($launched.PSObject.Properties.Name -contains 'error'){throw $launched.error}
                $process=Get-Process -Id $launched.pid
            } finally {Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue}
            $process.Refresh()
            $receipt=[pscustomobject]@{pid=$process.Id;started=$process.StartTime.ToUniversalTime().Ticks.ToString();executable=$exe;artifactDigest=$digest;proof=$request.proof;taskName=$taskName;launchMode=$mode}
            $deadline=[DateTime]::UtcNow.AddSeconds(30);$evidence=$null
            while([DateTime]::UtcNow -lt $deadline){
                try {$evidence=Get-DevBarEvidence $c $receipt;break}catch{Start-Sleep -Milliseconds 200}
            }
            if(!$evidence){throw 'Windows application failed runtime proof'}
            $receipt | Add-Member -NotePropertyName instanceID -NotePropertyValue $evidence.instanceID
            $temp=$receiptPath+'.tmp';$receipt|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $temp -Encoding utf8;Move-Item -LiteralPath $temp -Destination $receiptPath -Force
            if($moved){Remove-Item -LiteralPath $backup -Recurse -Force}
            return $evidence
        } catch {
            if($process -and !$process.HasExited){Stop-Process -Id $process.Id -ErrorAction SilentlyContinue}
            if($taskName){Remove-DevBarTask ([pscustomobject]@{taskName=$taskName})}
            if($installed -and (Test-Path -LiteralPath $dest)){Remove-Item -LiteralPath $dest -Recurse -Force}
            if($moved){Move-Item -LiteralPath $backup -Destination $dest}
            # Restored bytes are preserved; a stopped previous process is not reported current.
            throw
        } finally {if(Test-Path -LiteralPath $new){Remove-Item -LiteralPath $new -Recurse -Force}}
    } finally {$lock.Dispose()}
}
