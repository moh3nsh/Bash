<#
  install.ps1 - one-time setup of the DB backup toolkit on a Windows SQL Server.

  Run in PowerShell "as Administrator" from the folder that holds backup.ps1:

    powershell -ExecutionPolicy Bypass -File .\install.ps1 `
        -ServerName "tose-salamat" `
        -SqlInstance "localhost\SEPIDAR" `
        -BackupDir "E:\Backup_Cloud" `
        -Remote "parspack:BUCKET/tose-salamat"

  Prerequisites (not done here, on purpose):
    * rclone.exe unpacked (default C:\rclone\rclone.exe) and a remote configured
      in rclone.conf (edit the file with notepad, never paste keys in chat/history).
    * sqlcmd available, and the account used for the task is sysadmin in SQL Server.
#>
param(
    [Parameter(Mandatory = $true)][string]$ServerName,
    [Parameter(Mandatory = $true)][string]$BackupDir,
    [Parameter(Mandatory = $true)][string]$Remote,
    [string]$SqlInstance   = 'localhost',
    [string]$At            = '02:00',
    [string]$InstallDir    = 'C:\Scripts\DbBackup',
    [string]$RcloneExe     = 'C:\rclone\rclone.exe',
    [string]$RcloneConf    = 'C:\rclone\rclone.conf',
    [int]$KeepLocalDays    = 3,
    [int]$KeepCloudDays    = 90,
    [double]$MinFreeGB     = 5,
    [string[]]$ExcludeDatabases = @(),
    [string]$TaskName      = 'DbBackup-Cloud',
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# admin check
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Run PowerShell as Administrator.'
}

Step 'Checking prerequisites'
if (-not (Test-Path (Join-Path $PSScriptRoot 'backup.ps1'))) { Fail "backup.ps1 not found next to install.ps1" }
# rclone: use the copy next to this script, else download it from rclone.org
if (-not (Test-Path $RcloneExe)) {
    New-Item -ItemType Directory -Path (Split-Path $RcloneExe) -Force | Out-Null
    $local = Join-Path $PSScriptRoot 'rclone\rclone.exe'
    $bundleZip = @((Join-Path $PSScriptRoot 'rclone'), $PSScriptRoot, (Split-Path $PSScriptRoot)) |
        Where-Object { Test-Path $_ } |
        ForEach-Object { Get-ChildItem $_ -Filter 'rclone*windows-amd64.zip' -File -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (Test-Path $local) {
        Step "Copying bundled rclone to $RcloneExe"
        Copy-Item $local $RcloneExe -Force
    }
    elseif ($bundleZip) {
        Step "Unpacking bundled $($bundleZip.Name)"
        $tmp = Join-Path $env:TEMP 'rclone_unpack'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive $bundleZip.FullName $tmp -Force
        $found = Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1
        if (-not $found) { Fail "rclone.exe not found inside $($bundleZip.FullName)" }
        Copy-Item $found.FullName $RcloneExe -Force
    }
    else {
        Step 'Downloading rclone from downloads.rclone.org'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $env:TEMP 'rclone.zip'
            $tmp = Join-Path $env:TEMP 'rclone_unpack'
            Invoke-WebRequest 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile $zip -UseBasicParsing
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive $zip $tmp -Force
            $found = Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1
            Copy-Item $found.FullName $RcloneExe -Force
        }
        catch { Fail "Could not get rclone ($($_.Exception.Message)). Put rclone.exe in $PSScriptRoot\rclone\ and run again." }
    }
}
if (-not (Test-Path $RcloneConf)) {
    $tpl = Join-Path $PSScriptRoot 'rclone.conf.template'
    if (Test-Path $tpl) { Copy-Item $tpl $RcloneConf -Force }
    Fail "rclone config was missing. A template was copied to $RcloneConf - edit it with: notepad $RcloneConf  (fill endpoint + keys), then run install.ps1 again."
}
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { Fail 'sqlcmd not found in PATH' }

$sa = & sqlcmd -S $SqlInstance -E -h -1 -W -Q "SET NOCOUNT ON; SELECT IS_SRVROLEMEMBER('sysadmin')" 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail "Cannot connect to SQL instance '$SqlInstance': $sa" }
if ($sa.Trim() -ne '1') { Write-Warning 'Current user is NOT sysadmin. The scheduled-task user must be.' }

$remoteName = $Remote.Split(':')[0] + ':'
& $RcloneExe lsd $remoteName --config $RcloneConf | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "rclone cannot list '$remoteName' - check endpoint/keys in $RcloneConf" }

Step "Installing to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir, $BackupDir -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'backup.ps1') (Join-Path $InstallDir 'backup.ps1') -Force

$cfg = [ordered]@{
    ServerName       = $ServerName
    SqlInstance      = $SqlInstance
    BackupDir        = $BackupDir
    Remote           = $Remote
    RcloneExe        = $RcloneExe
    RcloneConf       = $RcloneConf
    KeepLocalDays    = $KeepLocalDays
    KeepCloudDays    = $KeepCloudDays
    MinFreeGB        = $MinFreeGB
    Compression      = $true
    ExcludeDatabases = @($ExcludeDatabases)
    Databases        = @()
}
$cfgPath = Join-Path $InstallDir 'backup.config.json'
($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8
Write-Host "Config written: $cfgPath"

# restrict the install folder to Administrators and SYSTEM
& icacls $InstallDir /inheritance:r /grant 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null

if ($NoTask) {
    Step 'Skipping scheduled task (-NoTask)'
}
else {
    Step "Registering scheduled task '$TaskName' daily at $At"
    Write-Host 'Enter the Windows account that runs the backup (must be SQL sysadmin; not SYSTEM).'
    $cred = Get-Credential
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\backup.ps1`""
    $trg = New-ScheduledTaskTrigger -Daily -At $At
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set `
        -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
}

Step 'Done. Next:'
Write-Host "  1) Test:  powershell -ExecutionPolicy Bypass -File $InstallDir\backup.ps1"
Write-Host "  2) Log:   Get-Content $BackupDir\backup_log.txt -Tail 10"
Write-Host "  3) Cloud: $RcloneExe ls $Remote/$ServerName --config $RcloneConf"
if (-not $NoTask) { Write-Host "  4) Task:  Start-ScheduledTask -TaskName $TaskName; Get-ScheduledTaskInfo -TaskName $TaskName" }
