<#
  Automating Full Database Backups - setup.ps1
  Contact: mohsen.shiirazii@gmail.com
  One-click, re-runnable setup + updater for the DB backup toolkit.
  Start it with Setup.cmd (extracted zip folder). It:
    1. elevates to Administrator, checks for a newer toolkit version on GitHub (and applies it)
    2. finds/installs rclone, creates rclone.conf (asks for the Parspack keys locally)
    3. finds sqlcmd and the SQL instance automatically, finds the bucket
    4. writes/migrates backup.config.json, installs backup.ps1 to C:\Scripts\DbBackup
    5. registers the daily scheduled task (re-registers only if something changed)
    6. runs a test backup and shows the result
  Running it again later = health check: it reports and fixes whatever is outdated or broken.
  Windows PowerShell 5.1 compatible.
#>
param(
    [string]$ServerName, [string]$SqlInstance, [string]$BackupDir, [string]$Remote, [string]$At,
    [switch]$NoTask, [switch]$NoTest, [switch]$NoUpdateCheck, [switch]$Unattended, [switch]$Force
)
$ErrorActionPreference = 'Stop'
$Here        = $PSScriptRoot
$InstallDir  = 'C:\Scripts\DbBackup'
$RcloneExe   = 'C:\rclone\rclone.exe'
$RcloneConf  = 'C:\rclone\rclone.conf'
$TaskName    = 'DbBackup-Cloud'
$Report      = New-Object System.Collections.ArrayList

# ---- elevate ----------------------------------------------------------------
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argl += "-$k" } } else { $argl += "-$k"; $argl += "`"$v`"" }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $argl
    exit
}

function Step($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Note($tag, $m) { [void]$Report.Add("[$tag] $m"); $col = 'Gray'; if ($tag -eq 'FIXED') { $col = 'Green' } elseif ($tag -eq 'WARN') { $col = 'Yellow' }; Write-Host "    [$tag] $m" -ForegroundColor $col }
function Ask($q, $def) {
    if ($Unattended) { return $def }
    $r = Read-Host "$q [$def]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $def }
    return $r.Trim()
}
function Confirm-Yes($q) {
    if ($Unattended) { return $true }
    $r = Read-Host "$q [Y/n]"
    return ([string]::IsNullOrWhiteSpace($r) -or $r -match '^(y|yes|Y)')
}
function Pick($param, $old, $default) {
    if ($param) { return $param }
    if ($null -ne $old -and "$old" -ne '') { return $old }
    return $default
}
function Same-File($a, $b) {
    if (-not (Test-Path $a) -or -not (Test-Path $b)) { return $false }
    return ((Get-FileHash $a).Hash -eq (Get-FileHash $b).Hash)
}

try {
    if (-not (Test-Path (Join-Path $Here 'backup.ps1'))) {
        throw "backup.ps1 not found next to setup.ps1. Extract the whole zip first, then run Setup.cmd from the extracted folder."
    }
    $defaults = Get-Content (Join-Path $Here 'toolkit.defaults.json') -Raw | ConvertFrom-Json
    $localVer = (Get-Content (Join-Path $Here 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $localVer) { $localVer = '0.0.0' }
    $Host.UI.RawUI.WindowTitle = 'Automating Full Database Backups'
    Write-Host ''
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host '   Automating Full Database Backups' -ForegroundColor White
    Write-Host "   Version $localVer" -ForegroundColor Gray
    Write-Host '   Contact: mohsen.shiirazii@gmail.com' -ForegroundColor Gray
    Write-Host '  ==============================================' -ForegroundColor Cyan
    Write-Host ''

    # ---- 1. update check ----------------------------------------------------
    if (-not $NoUpdateCheck -and $defaults.UpdateBase) {
        Step 'Checking for a newer toolkit version'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $rv = ((Invoke-WebRequest "$($defaults.UpdateBase)/VERSION" -UseBasicParsing -TimeoutSec 10).Content).Trim()
            if ([version]$rv -gt [version]$localVer) {
                Note 'WARN' "Newer version available: $localVer -> $rv"
                if (Confirm-Yes "Download and apply v$rv now?") {
                    $files = 'backup.ps1', 'setup.ps1', 'Setup.cmd', 'VERSION', 'toolkit.defaults.json'
                    $tmp = Join-Path $env:TEMP "dbbackup_update_$rv"
                    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
                    New-Item -ItemType Directory $tmp | Out-Null
                    foreach ($f in $files) {
                        Invoke-WebRequest "$($defaults.UpdateBase)/$f" -OutFile (Join-Path $tmp $f) -UseBasicParsing -TimeoutSec 30
                        if ((Get-Item (Join-Path $tmp $f)).Length -eq 0) { throw "empty download: $f" }
                        if ($f -like '*.ps1') { [void][scriptblock]::Create((Get-Content (Join-Path $tmp $f) -Raw)) }  # must parse
                    }
                    foreach ($f in $files) { Copy-Item (Join-Path $tmp $f) (Join-Path $Here $f) -Force }
                    Note 'FIXED' "Toolkit updated to v$rv - restarting setup with the new files"
                    $re = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Here 'setup.ps1')`"", '-NoUpdateCheck')
                    foreach ($k in $PSBoundParameters.Keys) {
                        if ($k -eq 'NoUpdateCheck') { continue }
                        $v = $PSBoundParameters[$k]
                        if ($v -is [switch]) { if ($v) { $re += "-$k" } } else { $re += "-$k"; $re += "`"$v`"" }
                    }
                    & powershell @re
                    exit $LASTEXITCODE
                }
            }
            else { Note 'OK' "Toolkit is up to date (v$localVer)" }
        }
        catch { Note 'WARN' "Update check skipped ($($_.Exception.Message))" }
    }

    # ---- 2. rclone ------------------------------------------------------------
    Step 'rclone'
    if (-not (Test-Path $RcloneExe)) {
        New-Item -ItemType Directory -Path (Split-Path $RcloneExe) -Force | Out-Null
        $local = Join-Path $Here 'rclone\rclone.exe'
        $bundleZip = @((Join-Path $Here 'rclone'), $Here, (Split-Path $Here)) |
            Where-Object { Test-Path $_ } |
            ForEach-Object { Get-ChildItem $_ -Filter 'rclone*windows-amd64.zip' -File -ErrorAction SilentlyContinue } |
            Select-Object -First 1
        $tmp = Join-Path $env:TEMP 'rclone_unpack'
        if (Test-Path $local) { Copy-Item $local $RcloneExe -Force }
        else {
            if ($bundleZip) { $zip = $bundleZip.FullName }
            else {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $zip = Join-Path $env:TEMP 'rclone.zip'
                    Invoke-WebRequest 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -OutFile $zip -UseBasicParsing
                }
                catch { throw "Could not get rclone ($($_.Exception.Message)). Put rclone.exe (or rclone-*-windows-amd64.zip) in $Here\rclone\ and run Setup.cmd again." }
            }
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            Expand-Archive $zip $tmp -Force
            $found = Get-ChildItem $tmp -Recurse -Filter rclone.exe | Select-Object -First 1
            if (-not $found) { throw "rclone.exe not found inside $zip" }
            Copy-Item $found.FullName $RcloneExe -Force
        }
        Note 'FIXED' "rclone installed to $RcloneExe"
    }
    else { Note 'OK' "rclone present ($RcloneExe)" }

    # Keys are stored encrypted (Windows DPAPI, machine scope) in C:\rclone\rclone.secret,
    # NOT in rclone.conf, so opening rclone.conf in notepad shows nothing secret.
    Add-Type -AssemblyName System.Security
    $SecretFile = 'C:\rclone\rclone.secret'
    function Save-Secret($ep, $ak, $sk) {
        $json = (@{ Endpoint = $ep; AccessKey = $ak; SecretKey = $sk } | ConvertTo-Json -Compress)
        $p = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        New-Item -ItemType Directory -Path (Split-Path $SecretFile) -Force | Out-Null
        Set-Content -Path $SecretFile -Value ([Convert]::ToBase64String($p)) -Encoding ASCII
        & icacls $SecretFile /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
    }
    function Load-RcloneEnv {
        if (-not (Test-Path $SecretFile)) { return $false }
        $b = [Convert]::FromBase64String((Get-Content $SecretFile -Raw).Trim())
        $j = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)) | ConvertFrom-Json
        $env:RCLONE_CONFIG_PARSPACK_TYPE = 's3'
        $env:RCLONE_CONFIG_PARSPACK_PROVIDER = 'Other'
        $env:RCLONE_CONFIG_PARSPACK_ENDPOINT = $j.Endpoint
        $env:RCLONE_CONFIG_PARSPACK_ACCESS_KEY_ID = $j.AccessKey
        $env:RCLONE_CONFIG_PARSPACK_SECRET_ACCESS_KEY = $j.SecretKey
        $env:RCLONE_CONFIG_PARSPACK_NO_CHECK_BUCKET = 'true'
        return $true
    }
    function Test-Remote { & $RcloneExe lsd 'parspack:' --config $RcloneConf 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) }

    # migrate an old plaintext rclone.conf (keys visible in notepad) to the encrypted file
    if (-not (Test-Path $SecretFile) -and (Test-Path $RcloneConf)) {
        $txt = Get-Content $RcloneConf -Raw
        $mAk = [regex]::Match($txt, '(?m)^\s*access_key_id\s*=\s*(\S+)')
        $mSk = [regex]::Match($txt, '(?m)^\s*secret_access_key\s*=\s*(\S+)')
        $mEp = [regex]::Match($txt, '(?m)^\s*endpoint\s*=\s*(\S+)')
        if ($mAk.Success -and $mSk.Success -and $mAk.Groups[1].Value -notmatch 'PUT_') {
            $ep0 = $defaults.Endpoint; if ($mEp.Success) { $ep0 = $mEp.Groups[1].Value }
            Save-Secret $ep0 $mAk.Groups[1].Value $mSk.Groups[1].Value
            Note 'FIXED' 'keys moved from rclone.conf into the encrypted rclone.secret'
        }
    }
    [void](Load-RcloneEnv)
    $tries = 0
    while (-not (Test-Path $SecretFile) -or -not (Test-Remote)) {
        $tries++
        if ($tries -gt 3) { throw 'rclone cannot access the cloud. Check the endpoint and keys.' }
        if ($Unattended) { throw 'No working keys and -Unattended was given' }
        if (Test-Path $SecretFile) { Note 'WARN' 'rclone cannot list the cloud with the stored keys - enter them again' }
        else { Note 'WARN' 'no keys stored yet - enter them (typed here, hidden, stored encrypted)' }
        $ep  = Ask 'Parspack endpoint' $defaults.Endpoint
        $sa1 = Read-Host 'Access key (hidden)' -AsSecureString
        $sec = Read-Host 'Secret key (hidden)' -AsSecureString
        $ak  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sa1))
        $sk  = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        Save-Secret $ep $ak.Trim() $sk.Trim()
        $sk = $null; $ak = $null
        [void](Load-RcloneEnv)
    }
    # rclone.conf stays as an empty file (the remote comes from the encrypted secrets at run time)
    Set-Content -Path $RcloneConf -Value '# no secrets here - see rclone.secret (encrypted)' -Encoding ASCII
    Note 'OK' 'rclone can reach Parspack'

    # bucket
    $buckets = @(& $RcloneExe lsd 'parspack:' --config $RcloneConf 2>$null | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ })
    $bucket = $defaults.Bucket
    if ($buckets.Count -gt 0 -and ($buckets -notcontains $bucket)) {
        if ($buckets.Count -eq 1) { $bucket = $buckets[0] }
        else { $bucket = Ask ("Bucket (found: " + ($buckets -join ', ') + ")") $buckets[0] }
        Note 'WARN' "Default bucket not found in this account - using '$bucket'"
    }

    # ---- 3. SQL Server ----------------------------------------------------------
    Step 'SQL Server'
    function Find-Sqlcmd {
        $cmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        foreach ($p in @('C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\*\Tools\Binn\sqlcmd.exe',
                         'C:\Program Files\Microsoft SQL Server\*\Tools\Binn\sqlcmd.exe',
                         'C:\Program Files (x86)\Microsoft SQL Server\*\Tools\Binn\sqlcmd.exe')) {
            $f = Get-ChildItem $p -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
        return $null
    }
    $Sqlcmd = Find-Sqlcmd
    if (-not $Sqlcmd) { throw 'sqlcmd.exe not found on this server. Install "Microsoft Command Line Utilities for SQL Server" and run Setup.cmd again.' }
    Note 'OK' "sqlcmd: $Sqlcmd"

    $cfgPath = Join-Path $InstallDir 'backup.config.json'
    $old = $null
    if (Test-Path $cfgPath) { try { $old = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { Note 'WARN' 'existing config unreadable - rebuilding' } }

    $instance = $SqlInstance
    if (-not $instance -and $old) { $instance = $old.SqlInstance }
    if (-not $instance) {
        $cands = @()
        foreach ($s in (Get-Service | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' })) {
            $inst = 'localhost'
            if ($s.Name -ne 'MSSQLSERVER') { $inst = 'localhost\' + $s.Name.Substring(6) }
            $n = -1
            if ($s.Status -eq 'Running') {
                $r = & $Sqlcmd -S $inst -E -h -1 -W -Q 'SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE database_id > 4' 2>$null
                if ($LASTEXITCODE -eq 0) { $n = [int](($r | Out-String).Trim()) }
            }
            $cands += [pscustomobject]@{ Instance = $inst; Dbs = $n; Status = $s.Status }
        }
        if ($cands.Count -eq 0) { throw 'No SQL Server service found on this machine. Use -SqlInstance "host\NAME".' }
        $cands = @($cands | Sort-Object Dbs -Descending)
        if ($cands.Count -gt 1) { $cands | ForEach-Object { Write-Host ("    {0}  (user databases: {1}, {2})" -f $_.Instance, $_.Dbs, $_.Status) } }
        $instance = $cands[0].Instance
        if ($cands.Count -gt 1) { $instance = Ask 'SQL instance to back up' $instance }
        Note 'FIXED' "SQL instance detected: $instance"
    }
    $sa = & $Sqlcmd -S $instance -E -h -1 -W -Q 'SET NOCOUNT ON; SELECT IS_SRVROLEMEMBER(''sysadmin'')' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Cannot connect to SQL instance '$instance': $sa" }
    if ($sa.Trim() -ne '1') { Note 'WARN' 'Current user is NOT sysadmin. The scheduled-task account must be.' } else { Note 'OK' "Connected to $instance as sysadmin" }

    # ---- 4. config + files --------------------------------------------------
    Step 'Installing files and config'
    $label  = Pick $ServerName ($(if ($old) { $old.ServerName })) ($env:COMPUTERNAME.ToLower())
    if (-not $ServerName -and -not $old) { $label = Ask 'Server name (folder name in the cloud)' $label }
    $bdir   = Pick $BackupDir ($(if ($old) { $old.BackupDir })) 'C:\Backup_Cloud'
    $remote = Pick $Remote ($(if ($old) { $old.Remote })) "parspack:$bucket"
    $time   = Pick $At ($(if ($old) { $old.At })) $defaults.At

    New-Item -ItemType Directory -Path $InstallDir, $bdir -Force | Out-Null
    foreach ($f in 'backup.ps1', 'VERSION') {
        $src = Join-Path $Here $f; $dst = Join-Path $InstallDir $f
        if (Same-File $src $dst) { Note 'OK' "$f unchanged" } else { Copy-Item $src $dst -Force; Note 'FIXED' "$f installed/updated" }
    }
    function Old($n, $d) { if ($old -and $null -ne $old.$n -and "$($old.$n)" -ne '') { return $old.$n } else { return $d } }
    $cfg = [ordered]@{
        ServerName       = $label
        SqlInstance      = $instance
        SqlcmdExe        = $Sqlcmd
        BackupDir        = $bdir
        Remote           = $remote
        At               = $time
        RcloneExe        = $RcloneExe
        RcloneConf       = $RcloneConf
        KeepLocalDays    = [int](Old 'KeepLocalDays' 3)
        KeepCloudCount   = [int](Old 'KeepCloudCount' 10)   # newest N daily backups per database in the cloud
        KeepLongDays     = [int](Old 'KeepLongDays' 30)     # one extra long-term copy per database, kept this many days (0 = off)
        MinFreeGB        = [double](Old 'MinFreeGB' 5)
        Compression      = $true
        ExcludeDatabases = @(Old 'ExcludeDatabases' @())
        Databases        = @(Old 'Databases' @())
        UpdateBase       = $defaults.UpdateBase
    }
    $json = $cfg | ConvertTo-Json
    $tmpCfg = Join-Path $env:TEMP 'dbbackup.config.new'
    Set-Content $tmpCfg $json -Encoding UTF8
    if (Same-File $tmpCfg $cfgPath) { Note 'OK' 'config unchanged' } else { Copy-Item $tmpCfg $cfgPath -Force; Note 'FIXED' "config written: $cfgPath" }
    & icacls $InstallDir /inheritance:r /grant 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
    Note 'OK' "backups go to $bdir  ->  cloud $remote/$label/<db>  (keep newest $($cfg.KeepCloudCount) + one copy for $($cfg.KeepLongDays) days)"

    # ---- 5. scheduled task ---------------------------------------------------
    if ($NoTask) { Note 'OK' 'scheduled task skipped (-NoTask)' }
    else {
        Step "Scheduled task '$TaskName'"
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $needTask = $true
        if ($t -and -not $Force) {
            $t0 = ($t.Triggers | Select-Object -First 1).StartBoundary
            $curTime = ''
            if ($t0) { $curTime = ([datetime]$t0).ToString('HH:mm') }
            $curArg  = $t.Actions[0].Arguments
            $wantArg = "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\backup.ps1`""
            if ($curTime -eq $time -and $curArg -eq $wantArg) { $needTask = $false; Note 'OK' "task exists: daily $curTime as $($t.Principal.UserId)" }
            else { Note 'WARN' "task differs (time '$curTime' vs '$time', or command changed) - re-registering" }
        }
        if ($needTask) {
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\backup.ps1`""
            $trg = New-ScheduledTaskTrigger -Daily -At $time
            $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
            $done = $false
            for ($i = 1; $i -le 3 -and -not $done; $i++) {
                Write-Host 'Windows account that runs the backup (must be SQL sysadmin):'
                $cred = Get-Credential -UserName "$env:COMPUTERNAME\$env:USERNAME" -Message 'Account that runs the nightly backup'
                if (-not $cred) { continue }
                $u = $cred.UserName
                if ($u -notmatch '\\' -and $u -notmatch '@') { $u = ".\$u" }
                try {
                    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set `
                        -User $u -Password $cred.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
                    $done = $true
                    & icacls $RcloneConf /grant "${u}:R" 2>$null | Out-Null
                    & icacls $SecretFile /grant "${u}:R" 2>$null | Out-Null
                    Note 'FIXED' "task registered: daily $time as $u"
                }
                catch { Note 'WARN' "Register failed: $($_.Exception.Message)  (check user/password; local account form is .\Name)" }
            }
            if (-not $done) { throw 'Scheduled task was not registered.' }
        }
    }

    # ---- 6. test run -----------------------------------------------------------
    $rc = 0
    if (-not $NoTest -and (Confirm-Yes 'Run a full test backup now (also uploads to the cloud)?')) {
        Step 'Test backup'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'backup.ps1')
        $rc = $LASTEXITCODE
        Write-Host '--- last log lines ---'
        Get-Content (Join-Path $bdir 'backup_log.txt') -Tail 12 -ErrorAction SilentlyContinue
        if ($rc -eq 0) { Note 'OK' 'test backup succeeded (see log above)' } else { Note 'WARN' "test backup had $rc failure(s) - see log" }
        Write-Host '--- in the cloud ---'
        & $RcloneExe ls "$remote/$label" --config $RcloneConf
    }

    Write-Host ''
    Step 'Summary'
    $Report | ForEach-Object { Write-Host "  $_" }
    if (-not $Unattended) { Read-Host 'Done. Press Enter to close' | Out-Null }
    exit $rc
}
catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Fix the problem above and run Setup.cmd again (it is safe to re-run).' -ForegroundColor Yellow
    if (-not $Unattended) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
