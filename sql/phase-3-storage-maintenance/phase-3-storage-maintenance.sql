/*
================================================================================
Phase 3: Storage & Database Maintenance
================================================================================
This script contains every T-SQL command I ran during Phase 3, in the order
I ran them. Covers: filegroup/file layout review, log file capacity issue
discovery and fix, data file capacity planning, integrity checking, and
statistics maintenance on climate_dba.
================================================================================
*/

-- ============================================================================
-- STEP 1: Review current database file layout
-- ============================================================================
USE climate_dba;
GO

SELECT
    name AS logical_name,
    physical_name,
    type_desc,
    size / 128 AS size_MB,
    growth,
    is_percent_growth
FROM sys.database_files;
GO

/*
Findings: log file (13,064 MB) was larger than the data file (5,960 MB) -
unusual, worth investigating rather than ignoring.
*/

-- ============================================================================
-- STEP 2: Investigate the oversized log file
-- ============================================================================
-- Checked recovery model - climate_dba was created under FULL recovery
-- (SQL Server's default), meaning every row from all four bulk loads
-- (132,501 station rows + 113.5M observation rows) was fully logged.
SELECT
    name,
    recovery_model_desc
FROM sys.databases
WHERE name = 'climate_dba';
GO

-- Confirmed log space actually in use before deciding to shrink
DBCC SQLPERF(LOGSPACE);
GO

/*
Result: climate_dba log was 13,064 MB but only 15.12% actually in use -
roughly 11.7GB of reclaimable empty space. Confirms the bulk-load-under-
FULL-recovery theory.

Decision: kept FULL recovery model intact (Phase 5 needs it for the
point-in-time restore drill), but shrank the log file as a one-time
cleanup - a legitimate use case for DBCC SHRINKFILE, not something to
repeat routinely.
*/

-- ============================================================================
-- STEP 3: Shrink the log file
-- ============================================================================
DBCC SHRINKFILE (climate_dba_log, 1000);
GO

-- Verified: log shrank from 13,064 MB to ~1,032 MB
DBCC SQLPERF(LOGSPACE);
GO

-- ============================================================================
-- STEP 4: Check data file space usage
-- ============================================================================
EXEC sp_spaceused;
GO

/*
Findings: database showed only 7.40 MB of unallocated space remaining in
a 5,960 MB data file - essentially full. With a fixed 64MB growth
increment, this meant frequent small autogrowth events were imminent -
a classic real-world problem (fragmentation, growth-event write pauses).
*/

-- ============================================================================
-- STEP 5: Proactive capacity planning - grow data file, fix growth increment
-- ============================================================================
-- Reasoning: current data (~5,948MB) + Phase 4's future indexes (typically
-- 15-30% overhead on a table this wide) puts a near-term ceiling around
-- 8,000-9,000 MB. Grew to 10,000 MB for comfortable headroom. Growth
-- increment raised from 64MB to 1024MB (1GB) - large enough to avoid
-- frequent growth events as the database grows further in later phases.
ALTER DATABASE climate_dba
MODIFY FILE
(
    NAME = climate_dba,
    SIZE = 10000MB,
    FILEGROWTH = 1024MB
);
GO

-- Verified: data file now 10,000 MB with a 1024 MB (131,072 page) growth
-- increment, fixed-MB (not percentage-based)
SELECT
    name AS logical_name,
    size / 128 AS size_MB,
    growth,
    is_percent_growth
FROM sys.database_files
WHERE type_desc = 'ROWS';
GO

-- ============================================================================
-- STEP 6: Run a full integrity check
-- ============================================================================
-- Genuine health check before setting up ongoing maintenance routines.
DBCC CHECKDB ('climate_dba') WITH NO_INFOMSGS, ALL_ERRORMSGS;
GO

-- Result: completed successfully, zero allocation or consistency errors
-- found across the entire ~113.5 million row database.

-- ============================================================================
-- STEP 7: Check current statistics state
-- ============================================================================
SELECT
    OBJECT_NAME(s.object_id) AS table_name,
    s.name AS statistics_name,
    s.auto_created,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECT_NAME(s.object_id) IN ('daily_observations', 'stations')
ORDER BY table_name;
GO

/*
Findings: two auto-created statistics existed on daily_observations
(station_id and obs_date) - created reactively by the optimizer only
because Phase 1's baseline queries filtered on those columns. Both were
sampled at just 554,500 of 113,522,932 rows (~0.49%) - SQL Server's
default sampling behavior for large tables, not a full scan.
climate.stations had zero statistics, since nothing had queried it with
a filterable predicate yet.
*/

-- ============================================================================
-- STEP 8: Update statistics with a full scan
-- ============================================================================
-- Establishes accurate, complete statistics as part of an ongoing
-- maintenance routine, rather than relying on reactive auto-creation
-- with a small sample.
UPDATE STATISTICS climate.daily_observations WITH FULLSCAN;
UPDATE STATISTICS climate.stations WITH FULLSCAN;
GO

-- Verified: rows_sampled now exactly matches rows (113,522,932 =
-- 113,522,932) on both statistics objects - confirmed full scan.
SELECT
    OBJECT_NAME(s.object_id) AS table_name,
    s.name AS statistics_name,
    s.auto_created,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECT_NAME(s.object_id) IN ('daily_observations', 'stations')
ORDER BY table_name;
GO

/*
================================================================================
End of Phase 3 script.

Summary:
  - Log file: 13,064 MB (15.12% used) -> shrunk to ~1,032 MB. FULL recovery
    model kept intact for Phase 5's point-in-time restore drill.
  - Data file: 5,960 MB (nearly full, 7.4MB free) -> proactively grown to
    10,000 MB, growth increment raised from 64MB to 1024MB.
  - DBCC CHECKDB: clean, zero corruption found.
  - Statistics: found reactively auto-created with a 0.49% sample, updated
    to a full scan for accuracy.
  - Index maintenance: not applicable yet - zero indexes exist by design
    until Phase 4. Documented honestly rather than inventing work.

See docs/phase-3-storage-maintenance.md for the full narrative write-up
and screenshots.
================================================================================
*/
