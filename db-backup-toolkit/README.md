# DB Backup Toolkit (SQL Server -> Parspack/S3 via rclone)

Daily backup of every user database on a Windows SQL Server to an S3-compatible
bucket. The same zip/folder is used on every server; `Setup.cmd` does everything.

## Install / update / health-check on any server
1. Extract the zip (keep the folder structure), optionally drop `rclone.exe` or the rclone zip in `rclone\`.
2. Double-click **`Setup.cmd`** (it asks for Administrator itself).

It will, in order: check GitHub for a newer toolkit and apply it; install rclone; create
the encrypted key file `C:\rclone\rclone.secret` (asks for the Parspack access/secret key **locally**, hidden; the keys are never in the zip/git and never readable in `rclone.conf`); find `sqlcmd` and the SQL instance automatically; find the bucket; write the
config; install `backup.ps1` to `C:\Scripts\DbBackup`; register the daily 02:00 task; run a
test backup and show the cloud listing. Every step prints `[OK]`, `[FIXED]` or `[WARN]`.

**Re-running `Setup.cmd` is always safe**: it reports and fixes whatever is outdated or
broken (new version, changed script, missing rclone/config, missing or different task) and
leaves everything else alone. Existing settings are kept.

Unattended: `Setup.cmd -Unattended -NoTest` (needs `rclone.conf` already in place).
Overrides: `-ServerName`, `-SqlInstance`, `-BackupDir`, `-Remote`, `-At "21:00"`, `-NoTask`, `-Force`.

## What a nightly run does, per database
1. `BACKUP DATABASE ... COPY_ONLY, CHECKSUM` (compressed when the edition allows; Express cannot)
2. `RESTORE VERIFYONLY ... CHECKSUM`
3. `rclone copy` to `REMOTE/<ServerName>/<Database>/`, then `rclone check --size-only`
4. **Cloud retention (per database, only after that database succeeded):**
   keep the newest **10** backups; plus **one long-term copy** in
   `REMOTE/<ServerName>/_long/<Database>/` that is kept **30 days** (a new one is made
   when the previous is about 29 days old, so there is always one)
5. Local `.bak` files older than `KeepLocalDays` (3) are deleted if everything succeeded
6. Once a day it checks GitHub; if a newer version exists the log gets
   `UPDATE AVAILABLE ... run Setup.cmd` (it never updates itself silently)

Backups go to `C:\Backup_Cloud` (created automatically). `COPY_ONLY` keeps the application's own
backup chain (Sepidar, Rahkaran...) untouched. A lock file prevents overlapping runs; the run
aborts if the backup disk has less than `MinFreeGB` free.

## Files
| File | Purpose |
|---|---|
| `Setup.cmd` / `setup.ps1` | Installer, updater and health check |
| `backup.ps1` | The nightly job (installed to `C:\Scripts\DbBackup`) |
| `toolkit.defaults.json` | Non-secret defaults: endpoint, bucket, time, update URL |
| `VERSION` | Toolkit version (bump it when you change scripts and push) |
| `backup.config.example.json` | Reference for the per-server config |

## Releasing a change
Edit the scripts, raise the number in `VERSION`, commit and push. Servers are told by the log
(daily) and `Setup.cmd` offers to download and apply it. `UpdateBase` in
`toolkit.defaults.json` must be the raw-GitHub folder that holds these files (repo must be public,
or updates are simply skipped).

## Test / check by hand
```powershell
powershell -ExecutionPolicy Bypass -File C:\Scripts\DbBackup\backup.ps1
Get-Content C:\Backup_Cloud\backup_log.txt -Tail 20
C:\rclone\rclone.exe ls parspack:c719736/<ServerName> --config C:\rclone\rclone.conf
Get-ScheduledTaskInfo -TaskName DbBackup-Cloud
```
Restore test once a month on a spare server. Never commit `rclone.conf` or keys.

## Where the keys live
The Parspack keys are stored encrypted with Windows DPAPI (machine scope) in `C:\rclone\rclone.secret`, readable only by Administrators/SYSTEM (and the task account); `rclone.conf` is an empty stub, so opening it in notepad shows no secret. An old plaintext `rclone.conf` is migrated automatically on the next `Setup.cmd`. Note: any local administrator can still decrypt it by script - this protects against casual viewing, not against an admin on the server.
