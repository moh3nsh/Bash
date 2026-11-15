<#
  Automating Full Database Backups (mohsen.shiirazii@gmail.com)
  backup.ps1 - generic SQL Server -> S3-compatible cloud backup (via rclone)

  Reads all settings from backup.config.json (same folder by default).
  For every user database: BACKUP (COPY_ONLY, CHECKSUM) -> RESTORE VERIFYONLY
  -> rclone upload -> size check in the cloud -> log.
  Retention: cloud keeps the newest KeepCloudCount (10) backups per database plus one
  long-term copy per database for KeepLongDays (30) days; local files KeepLocalDays.
  A database's old cloud files are pruned only when that database's backup succeeded.

  Usage:
    powershell -ExecutionPolicy Bypass -File backup.ps1
    powershell -ExecutionPolicy Bypass -File backup.ps1 -OnlyDb "SomeDb"
    powershell -ExecutionPolicy Bypass -File backup.ps1 -Config D:\other.json

  Exit code = number of failed databases (0 = all good).
  Compatible with Windows PowerShell 5.1 (Windows Server 2016/2019/2022).
#>
param(
    [string]$Config = (Join-Path $PSScriptRoot 'backup.config.json'),
    [string]$OnlyDb = ''
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path $Config)) { Write-Error "Config not found: $Config"; exit 99 }
$c = Get-Content $Config -Raw | ConvertFrom-Json

function Opt($name, $default) {
    $v = $c.$name
    if ($null -eq $v -or "$v" -eq '') { return $default }
    return $v
}

$Label         = Opt 'ServerName'    $env:COMPUTERNAME
$Instance      = Opt 'SqlInstance'   'localhost'
$Dir           = Opt 'BackupDir'     'C:\Backup_Cloud'
$Remote        = $c.Remote
$Sqlcmd        = Opt 'SqlcmdExe'     'sqlcmd'
$Rclone        = Opt 'RcloneExe'     'C:\rclone\rclone.exe'
$Conf          = Opt 'RcloneConf'    'C:\rclone\rclone.conf'
$KeepLocalDays = [int](Opt 'KeepLocalDays' 3)
$KeepCount     = [int](Opt 'KeepCloudCount' 10)   # newest N backups per database kept in the cloud
$KeepLongDays  = [int](Opt 'KeepLongDays' 30)     # plus one long-term copy per database kept this many days (0 = off)
$MinFreeGB     = [double](Opt 'MinFreeGB' 5)
$WantComp      = [bool](Opt 'Compression' $true)
$Exclude       = @($c.ExcludeDatabases | Where-Object { $_ })
$Include       = @($c.Databases | Where-Object { $_ })

# load the encrypted Parspack keys (written by Setup.cmd) into rclone's environment
$SecretFile = Join-Path (Split-Path $Conf) 'rclone.secret'
if (Test-Path $SecretFile) {
    try {
        Add-Type -AssemblyName System.Security
        $b = [Convert]::FromBase64String((Get-Content $SecretFile -Raw).Trim())
        $j = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)) | ConvertFrom-Json
        $env:RCLONE_CONFIG_PARSPACK_TYPE = 's3'
        $env:RCLONE_CONFIG_PARSPACK_PROVIDER = 'Other'
        $env:RCLONE_CONFIG_PARSPACK_ENDPOINT = $j.Endpoint
        $env:RCLONE_CONFIG_PARSPACK_ACCESS_KEY_ID = $j.AccessKey
        $env:RCLONE_CONFIG_PARSPACK_SECRET_ACCESS_KEY = $j.SecretKey
        $env:RCLONE_CONFIG_PARSPACK_NO_CHECK_BUCKET = 'true'
    } catch { Write-Error "Cannot read $SecretFile : $($_.Exception.Message)"; exit 99 }
}

if (-not $Remote) { Write-Error "Config is missing 'Remote'"; exit 99 }

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$Log  = Join-Path $Dir 'backup_log.txt'
$Lock = Join-Path $Dir 'backup.lock'

function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $Log
    Write-Host $m
}

function Prune-Cloud($db, $dest) {
    $names = @(& $Rclone lsf $dest --files-only --include "${db}_*.bak" --config $Conf 2>$null | Where-Object { $_ } | Sort-Object)
    if ($LASTEXITCODE -ne 0) { Log "RETENTION SKIPPED (cannot list cloud): $db"; return }
    if ($names.Count -gt $KeepCount) {
        foreach ($n in $names[0..($names.Count - $KeepCount - 1)]) {
            & $Rclone deletefile "$dest/$n" --config $Conf 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Log "Pruned old cloud backup: $db/$n" } else { Log "PRUNE FAILED: $db/$n" }
        }
    }
}

function Keep-Long($db, $latestName, $dest) {
    if ($KeepLongDays -le 0) { return }
    $ldest = "$Remote/$Label/_long/$db"
    $json = & $Rclone lsjson $ldest --files-only --config $Conf 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $json -notmatch 'not found') { Log "LONG-TERM SKIPPED (cannot list): $db"; return }
    $newest = $null
    if ($code -eq 0 -and $json.Trim()) {
        foreach ($i in @($json | ConvertFrom-Json)) {
            $t = $i.ModTime
            if ($t -isnot [datetime]) { $t = [datetime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
            $t = $t.ToUniversalTime()
            if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
        }
    }
    if ($null -eq $newest -or $newest -lt (Get-Date).ToUniversalTime().AddDays(-($KeepLongDays - 1))) {
        & $Rclone copyto "$dest/$latestName" "$ldest/$latestName" --config $Conf 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "Long-term copy created: $db/$latestName (kept $KeepLongDays days)" } else { Log "LONG-TERM COPY FAILED: $db"; return }
    }
    & $Rclone delete $ldest --min-age "$($KeepLongDays)d" --config $Conf 2>&1 | Out-Null
}

function Check-ForUpdate {
    try {
        $base = Opt 'UpdateBase' ''
        if (-not $base) { return }
        $stampF = Join-Path $Dir 'update_check.txt'
        if ((Test-Path $stampF) -and (Get-Item $stampF).LastWriteTime -gt (Get-Date).AddDays(-1)) { return }
        Set-Content $stampF (Get-Date -Format s)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $rv = ((Invoke-WebRequest "$base/VERSION" -UseBasicParsing -TimeoutSec 8).Content).Trim()
        $lv = (Get-Content (Join-Path $PSScriptRoot 'VERSION') | Select-Object -First 1).Trim()
        if ([version]$rv -gt [version]$lv) { Log "UPDATE AVAILABLE: v$lv -> v$rv  (run Setup.cmd from the toolkit folder on this server to update)" }
    } catch { }
}

# simple log rotation (keep one old file)
if ((Test-Path $Log) -and ((Get-Item $Log).Length -gt 5MB)) {
    Move-Item $Log "$Log.old" -Force
}

# single-instance lock (stale after 12h)
if (Test-Path $Lock) {
    if ((Get-Item $Lock).LastWriteTime -gt (Get-Date).AddHours(-12)) {
        Log 'SKIP: another run is active'
        exit 1
    }
}
New-Item $Lock -ItemType File -Force | Out-Null

$fail = 0
try {
    # preflight: tools present?
    if (-not (Test-Path $Rclone)) { Log "ABORT: rclone not found at $Rclone - run Setup.cmd again"; exit 1 }
    if (-not (Test-Path $Conf))   { Log "ABORT: rclone config not found at $Conf - run Setup.cmd again"; exit 1 }
    if ($Sqlcmd -ne 'sqlcmd' -and -not (Test-Path $Sqlcmd)) { Log "ABORT: sqlcmd not found at $Sqlcmd - run Setup.cmd again"; exit 1 }

    # free space on backup drive (needs a drive letter path like E:\...)
    $drive = $Dir.Substring(0, 1)
    $free  = [math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 1)
    if ($free -lt $MinFreeGB) {
        Log "ABORT: only $free GB free on ${drive}: (minimum $MinFreeGB GB)"
        exit 1
    }

    # database list
    if ($OnlyDb) {
        $dbs = @($OnlyDb)
    }
    elseif ($Include.Count -gt 0) {
        $dbs = $Include
    }
    else {
        $dbs = & $Sqlcmd -S $Instance -E -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND source_database_id IS NULL" |
               Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
        if ($LASTEXITCODE -ne 0) { Log "ABORT: cannot connect to SQL instance '$Instance'"; exit 1 }
    }
    $dbs = @($dbs | Where-Object { $Exclude -notcontains $_ })

    # compression is not available on Express edition
    $edition = (& $Sqlcmd -S $Instance -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(100))" | Out-String).Trim()
    $useComp = $WantComp -and ($edition -notmatch 'Express')

    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    Log "START [$Label] instance=$Instance edition='$edition' compression=$useComp dbs=$($dbs.Count) free=${free}GB"

    $opts = 'COPY_ONLY, CHECKSUM, INIT'
    if ($useComp) { $opts = 'COPY_ONLY, COMPRESSION, CHECKSUM, INIT' }

    foreach ($db in $dbs) {
        $name = "${db}_$stamp.bak"
        $file = Join-Path $Dir $name

        $out = & $Sqlcmd -S $Instance -E -b -Q "BACKUP DATABASE [$db] TO DISK = N'$file' WITH $opts" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) {
            Log "BACKUP FAILED: $db"; Log ($out | Out-String); $fail++; continue
        }

        $out = & $Sqlcmd -S $Instance -E -b -Q "RESTORE VERIFYONLY FROM DISK = N'$file' WITH CHECKSUM" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "VERIFY FAILED: $db"; Log ($out | Out-String); $fail++; continue
        }

        $dest = "$Remote/$Label/$db"
        $out = & $Rclone copy $file $dest --config $Conf 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "UPLOAD FAILED: $db"; Log ($out | Out-String); $fail++; continue
        }

        $out = & $Rclone check $Dir $dest --one-way --size-only --include $name --config $Conf 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "SIZE MISMATCH IN CLOUD: $db"; Log ($out | Out-String); $fail++; continue
        }

        $mb = [math]::Round((Get-Item $file).Length / 1MB, 1)
        Log "OK: $db ($mb MB)"
        Prune-Cloud $db $dest
        Keep-Long $db $name $dest
    }

    if ($fail -eq 0) {
        Get-ChildItem $Dir -Filter *.bak -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLocalDays) } |
            Remove-Item -Force
    }
    else {
        Log "WARNING: $fail failure(s) - old LOCAL backups were NOT deleted (cloud pruning only ran for databases that succeeded)"
    }
    Check-ForUpdate
    Log 'END'
}
finally {
    Remove-Item $Lock -ErrorAction SilentlyContinue
}
exit $fail
