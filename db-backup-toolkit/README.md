# DB Backup Toolkit (SQL Server -> S3-compatible cloud via rclone)

Nightly backup of every user database on a Windows SQL Server, uploaded to an
S3-compatible bucket (tested with Parspack). Same scripts for every server;
only `backup.config.json` differs.

## What it does per database
1. `BACKUP DATABASE ... WITH COPY_ONLY, CHECKSUM` (compression is used automatically
   when the edition supports it; Express edition does not).
2. `RESTORE VERIFYONLY ... WITH CHECKSUM`
3. `rclone copy` to `REMOTE/<ServerName>/<Database>/`
4. `rclone check --size-only` to confirm the file in the cloud matches
5. Log line `OK: <db> (<MB>)` or a `... FAILED` line with the SQL/rclone output

Old files (local `KeepLocalDays`, cloud `KeepCloudDays`) are deleted **only if all
databases succeeded**. `COPY_ONLY` keeps the backup chain of the application
(Sepidar, Rahkaran, ...) untouched. A lock file prevents overlapping runs, and the
run aborts if the backup disk has less than `MinFreeGB` free.

## Files
| File | Purpose |
|---|---|
| `backup.ps1` | The backup job, reads `backup.config.json` |
| `install.ps1` | One-time setup per server: checks, copies files, writes config, registers the scheduled task |
| `backup.config.example.json` | Config reference |

## Install on a new server
Prerequisites: `rclone.exe` unpacked at `C:\rclone`, a remote configured in
`C:\rclone\rclone.conf` (edit with `notepad`, do not paste keys into shells/chats),
and a Windows account that is `sysadmin` in SQL Server.

```powershell
# PowerShell as Administrator, inside this folder
powershell -ExecutionPolicy Bypass -File .\install.ps1 `
    -ServerName "customer-name" `
    -SqlInstance "localhost\INSTANCE" `
    -BackupDir "E:\Backup_Cloud" `
    -Remote "parspack:BUCKET/customer-name"
```
Choose a `BackupDir` on a disk with free space that is **not** the database disk.
Use a folder dedicated to this tool: it deletes old `*.bak` files in it.

Test by hand, then check the cloud:
```powershell
powershell -ExecutionPolicy Bypass -File C:\Scripts\DbBackup\backup.ps1
Get-Content E:\Backup_Cloud\backup_log.txt -Tail 10
C:\rclone\rclone.exe ls parspack:BUCKET/customer-name --config C:\rclone\rclone.conf
```
Exit code = number of failed databases (0 = OK). The scheduled task result
(`Get-ScheduledTaskInfo -TaskName DbBackup-Cloud`) shows the same code.

## Config keys
`ServerName` (cloud folder name), `SqlInstance`, `BackupDir`, `Remote`, `RcloneExe`,
`RcloneConf`, `KeepLocalDays`, `KeepCloudDays`, `MinFreeGB`, `Compression`,
`ExcludeDatabases` (names to skip), `Databases` (if non-empty, only these).

## Security notes
- Backups contain business/financial data. Get the customer's written approval
  before sending them off-site.
- The files in the bucket are **not encrypted** by this toolkit. Add an rclone
  `crypt` remote on top of the bucket (keep its password outside the server) and
  point `Remote` at it, e.g. `parspack-crypt:customer-name`.
- Never commit `rclone.conf` or keys. Rotate any key that was ever pasted into a
  chat or ticket.
- The install folder is restricted to Administrators/SYSTEM.

## Restore test (do this monthly)
Download one file with `rclone copy`, then on a test instance:
```sql
RESTORE DATABASE [TestRestore] FROM DISK = N'E:\Restore\file.bak'
WITH MOVE 'LogicalData' TO 'E:\Restore\t.mdf', MOVE 'LogicalLog' TO 'E:\Restore\t.ldf';
```
(`RESTORE FILELISTONLY FROM DISK = ...` shows the logical names.)

## Notes
- Windows PowerShell 5.1 compatible (Server 2016/2019/2022).
- The scripts contain no secrets and are safe to keep in git; `.gitignore` already
  excludes the per-server config and rclone.conf.
