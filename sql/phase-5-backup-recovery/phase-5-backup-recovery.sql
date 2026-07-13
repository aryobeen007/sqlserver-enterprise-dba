/*
================================================================================
Phase 5: Backup & Recovery
================================================================================
This script contains every T-SQL command I ran during Phase 5, in the order
I ran them. Covers: full/differential/log backup strategy, and a real
point-in-time recovery drill proving the backup chain actually works -
not just that backups can be taken.
================================================================================
*/

USE climate_dba;
GO

-- ============================================================================
-- STEP 1: Full backup
-- ============================================================================
-- Real result: 848,336 pages processed in 3.713 seconds (1784.981 MB/sec).
BACKUP DATABASE climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_full.bak'
WITH FORMAT, INIT, NAME = 'climate_dba-Full Backup', STATS = 10;
GO

-- Verified the backup file is valid and checked its metadata without
-- actually restoring anything.
RESTORE HEADERONLY
FROM DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_full.bak';
GO

-- Confirmed: BackupType = 1 (Full), BackupSize ~6.47GB, RecoveryModel = FULL

-- ============================================================================
-- STEP 2: Differential backup
-- ============================================================================
-- Real result: only 136 pages processed in 0.096 seconds - confirms the
-- differential mechanism correctly captured just the small amount of
-- changes since the full backup, not the whole database again.
BACKUP DATABASE climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_diff.bak'
WITH DIFFERENTIAL, FORMAT, INIT, NAME = 'climate_dba-Differential Backup', STATS = 10;
GO

-- ============================================================================
-- STEP 3: Transaction log backup
-- ============================================================================
-- This is the piece that actually enables point-in-time recovery - it
-- captures every transaction since the last log backup (or since the full
-- backup, if this is the first one taken).
BACKUP LOG climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_log.trn'
WITH FORMAT, INIT, NAME = 'climate_dba-Log Backup', STATS = 10;
GO

-- ============================================================================
-- STEP 4: Point-in-time recovery drill - proving the backup chain works
-- ============================================================================
-- Plan: make a real, identifiable data change, capture it in a log backup,
-- then restore to a point BEFORE that change happened, and verify the
-- change is genuinely gone. This proves recovery to a specific moment,
-- not just to the last backup.

-- Inserted a clearly-marked test row I can look for after the restore.
-- Change made at: 2026-07-13 11:51:06.477
INSERT INTO climate.stations (station_id, latitude, longitude, elevation, state, station_name)
VALUES ('TEST00000', '0.0', '0.0', '0', 'TS', 'PHASE5_RESTORE_TEST_MARKER');

SELECT GETDATE() AS change_made_at;
GO

-- Took a second log backup to capture this change. Used NOFORMAT/NOINIT
-- (append) rather than FORMAT/INIT (overwrite), since a real backup chain
-- keeps a sequence of log backups rather than wiping each one.
BACKUP LOG climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_log2.trn'
WITH NOFORMAT, NOINIT, NAME = 'climate_dba-Log Backup 2', STATS = 10;
GO

-- Confirmed the test marker genuinely exists before attempting the restore.
SELECT * FROM climate.stations WHERE station_id = 'TEST00000';
GO

-- ============================================================================
-- STEP 5: Execute the restore - full -> differential -> log -> log(STOPAT)
-- ============================================================================
USE master;
GO

-- Forcibly disconnect other connections since we're about to overwrite
-- the database.
ALTER DATABASE climate_dba SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

-- Restore the full backup with NORECOVERY - keeps the database in a
-- "restoring" state so more backups can be layered on top before the
-- database is brought back online.
RESTORE DATABASE climate_dba
FROM DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_full.bak'
WITH NORECOVERY, REPLACE, STATS = 10;
GO

-- Restore the differential backup, still NORECOVERY.
RESTORE DATABASE climate_dba
FROM DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_diff.bak'
WITH NORECOVERY, STATS = 10;
GO

-- Restore the first log backup, still NORECOVERY.
RESTORE LOG climate_dba
FROM DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_log.trn'
WITH NORECOVERY, STATS = 10;
GO

-- Restore the second log backup (containing the test marker insert), but
-- STOP at a point in time just BEFORE the insert happened (11:51:06.477).
-- This is the actual point-in-time recovery mechanism. RECOVERY (not
-- NORECOVERY) since this is the final step - brings the database online.
RESTORE LOG climate_dba
FROM DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_log2.trn'
WITH STOPAT = '2026-07-13 11:51:06.000', RECOVERY, STATS = 10;
GO

-- ============================================================================
-- STEP 6: Verify the restore worked - test marker should be GONE
-- ============================================================================
ALTER DATABASE climate_dba SET MULTI_USER;
GO

USE climate_dba;
GO

-- Result: zero rows returned - confirms the point-in-time restore
-- successfully recovered to a moment BEFORE the test insert happened.
SELECT * FROM climate.stations WHERE station_id = 'TEST00000';
GO

-- Sanity check: confirmed rest of the database is intact (not just that
-- the test row is gone). Results: 113,522,932 observation rows (unchanged),
-- 132,501 stations (exactly one less than it would be with the test row
-- still present) - confirms the restore removed exactly the test row and
-- nothing else.
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;
SELECT COUNT(*) AS total_stations FROM climate.stations;
GO

/*
================================================================================
End of Phase 5 script.

Summary:
  - Full backup: 848,336 pages, 3.713 seconds
  - Differential backup: 136 pages, 0.096 seconds
  - Log backup: 8 pages, 0.015 seconds
  - Point-in-time restore drill: test marker inserted at 11:51:06.477,
    restored to 11:51:06.000 (full -> diff -> log -> log with STOPAT) -
    verified the marker was genuinely absent after restore, and confirmed
    all other data (113,522,932 observations, 132,501 stations) intact.
  - Backup strategy designed against a 10-minute RPO requirement:
    weekly full, daily differential, log backups every 5 minutes
  - RTO estimated under 30 minutes based on real measured restore times
    (~15 seconds of pure processing time for the full chain)

See docs/phase-5-backup-recovery.md for the full narrative write-up,
disaster recovery plan, and screenshots.
================================================================================
*/
