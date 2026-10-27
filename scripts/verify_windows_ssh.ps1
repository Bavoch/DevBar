# Disposable CI runner only: exercise the real SSH/SFTP transport, not a fake SSH command.
$ErrorActionPreference='Stop'
$sshRoot=Join-Path $env:RUNNER_TEMP 'devbar-openssh'
New-Item -ItemType Directory -Path $sshRoot|Out-Null
Invoke-WebRequest 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.4.0.0p1-Preview/OpenSSH-Win64.zip' -OutFile "$sshRoot/openssh.zip"
Expand-Archive "$sshRoot/openssh.zip" -DestinationPath $sshRoot
$bin=Join-Path $sshRoot 'OpenSSH-Win64'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$bin/install-sshd.ps1"
if($LASTEXITCODE){throw 'OpenSSH server installation failed'}
$sshUser=Join-Path $env:USERPROFILE '.ssh';New-Item -ItemType Directory -Path $sshUser -Force|Out-Null
$key=Join-Path $sshUser 'devbar-e2e-key'
$env:DEVBAR_SSH_KEY=$key
$env:DEVBAR_SSH_KEYGEN=Join-Path $bin 'ssh-keygen.exe'
python -c "import subprocess,os;subprocess.run([os.environ['DEVBAR_SSH_KEYGEN'],'-t','ed25519','-N','','-f',os.environ['DEVBAR_SSH_KEY'],'-q'],check=True)"
if($LASTEXITCODE){throw 'Temporary SSH key generation failed'}
$authorized=Join-Path $env:ProgramData 'ssh/administrators_authorized_keys'
Get-Content "$key.pub"|Set-Content $authorized -Encoding ascii
& icacls.exe $authorized /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null
$sshdConfig=Join-Path $env:ProgramData 'ssh/sshd_config'
("LogLevel DEBUG3`nSyslogFacility LOCAL0`n"+(Get-Content $sshdConfig -Raw))|Set-Content $sshdConfig -Encoding ascii
& "$bin/sshd.exe" -t
if($LASTEXITCODE){throw 'Invalid temporary sshd configuration'}
Start-Service sshd
$known=Join-Path $sshUser 'devbar-known-hosts'
& "$bin/ssh-keyscan.exe" 127.0.0.1 2>$null|Set-Content $known -Encoding ascii
$settings=@"
Host devbar-windows-ci
 HostName 127.0.0.1
 User $env:USERNAME
 IdentityFile $($key.Replace('\','/'))
 UserKnownHostsFile $($known.Replace('\','/'))
 StrictHostKeyChecking yes
 BatchMode yes
"@
$settings|Set-Content (Join-Path $sshUser 'config') -Encoding ascii
$env:PATH="$bin;"+$env:PATH
& "$bin/ssh.exe" devbar-windows-ci whoami
if($LASTEXITCODE){Get-Content (Join-Path $env:ProgramData 'ssh/logs/sshd.log') -Tail 70;throw 'Real SSH authentication failed'}
python "$PSScriptRoot/verify_windows_ssh.py"
if($LASTEXITCODE){throw 'Windows SSH/SFTP driver E2E failed'}
