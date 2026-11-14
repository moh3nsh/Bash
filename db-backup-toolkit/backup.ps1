<#
  backup.ps1 - generic SQL Server -> S3-compatible cloud backup (via rclone)

  Reads all settings from backup.config.json (same folder by default).
  For every user database: BACKUP (COPY_ONLY, CHECKSUM) -> RESTORE VERIFYONLY
  -> rclone upload -> size check in the cloud -> log.
  Old files are deleted only when ALL databases succeeded.

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
$Dir           = Opt 'BackupDir'     'E:\Backup_Cloud'
$Remote        = $c.Remote
$Rclone        = Opt 'RcloneExe'     'C:\rclone\rclone.exe'
$Conf          = Opt 'RcloneConf'    'C:\rclone\rclone.conf'
$KeepLocalDays = [int](Opt 'KeepLocalDays' 3)
$KeepCloudDays = [int](Opt 'KeepCloudDays' 90)
$MinFreeGB     = [double](Opt 'MinFreeGB' 5)
$WantComp      = [bool](Opt 'Compression' $true)
$Exclude       = @($c.ExcludeDatabases | Where-Object { $_ })
$Include       = @($c.Databases | Where-Object { $_ })

if (-not $Remote) { Write-Error "Config is missing 'Remote'"; exit 99 }

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
$Log  = Join-Path $Dir 'backup_log.txt'
$Lock = Join-Path $Dir 'backup.lock'

function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Add-Content -Path $Log
    Write-Host $m
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
        $dbs = & sqlcmd -S $Instance -E -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 AND source_database_id IS NULL" |
               Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
        if ($LASTEXITCODE -ne 0) { Log "ABORT: cannot connect to SQL instance '$Instance'"; exit 1 }
    }
    $dbs = @($dbs | Where-Object { $Exclude -notcontains $_ })

    # compression is not available on Express edition
    $edition = (& sqlcmd -S $Instance -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(100))" | Out-String).Trim()
    $useComp = $WantComp -and ($edition -notmatch 'Express')

    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    Log "START [$Label] instance=$Instance edition='$edition' compression=$useComp dbs=$($dbs.Count) free=${free}GB"

    $opts = 'COPY_ONLY, CHECKSUM, INIT'
    if ($useComp) { $opts = 'COPY_ONLY, COMPRESSION, CHECKSUM, INIT' }

    foreach ($db in $dbs) {
        $name = "${db}_$stamp.bak"
        $file = Join-Path $Dir $name

        $out = & sqlcmd -S $Instance -E -b -Q "BACKUP DATABASE [$db] TO DISK = N'$file' WITH $opts" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) {
            Log "BACKUP FAILED: $db"; Log ($out | Out-String); $fail++; continue
        }

        $out = & sqlcmd -S $Instance -E -b -Q "RESTORE VERIFYONLY FROM DISK = N'$file' WITH CHECKSUM" 2>&1
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
    }

    if ($fail -eq 0) {
        & $Rclone delete "$Remote/$Label" --min-age "$($KeepCloudDays)d" --config $Conf 2>&1 | Out-Null
        Get-ChildItem $Dir -Filter *.bak -File |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLocalDays) } |
            Remove-Item -Force
    }
    else {
        Log "WARNING: $fail failure(s) - old backups were NOT deleted"
    }
    Log 'END'
}
finally {
    Remove-Item $Lock -ErrorAction SilentlyContinue
}
exit $fail
