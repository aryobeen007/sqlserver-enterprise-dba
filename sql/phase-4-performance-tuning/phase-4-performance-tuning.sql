/*
================================================================================
Phase 4: Performance Tuning
================================================================================
This script contains every T-SQL command I ran during Phase 4, in the order
I ran them. Approach followed Brent Ozar's methodology: measure first with
real wait stats and index usage data, diagnose based on evidence, make one
change at a time, then re-measure against the real baseline numbers already
documented in Phase 1 - never guess, never invent improvements.
================================================================================
*/

USE climate_dba;
GO

-- ============================================================================
-- STEP 1: Capture server-level wait stats as a real "before" baseline
-- ============================================================================
-- Filtered out the usual background-noise wait types that accumulate just
-- from the server being up and running, to focus on waits that actually
-- indicate contention or bottlenecks.
SELECT TOP 10
    wait_type,
    wait_time_ms,
    waiting_tasks_count,
    wait_time_ms / NULLIF(waiting_tasks_count, 0) AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK',
    'SLEEP_SYSTEMTASK','SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE',
    'CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT',
    'BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
    'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN','BROKER_EVENTHANDLER',
    'TRACEWRITE','FT_IFTSHC_MUTEX',
    -- additional background/housekeeping waits found in the actual results,
    -- added after the first pass showed my initial exclusion list was
    -- incomplete
    'SOS_WORK_DISPATCHER','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'DIRTY_PAGE_POLL','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','SP_SERVER_DIAGNOSTICS_SLEEP',
    'QDS_ASYNC_QUEUE'
)
ORDER BY wait_time_ms DESC;
GO

/*
Findings: the meaningful waits were CXPACKET (1,012,448 ms across 2,306,213
waiting tasks) and CXCONSUMER (785,184 ms across 74,885 tasks) - both are
parallelism synchronization waits, consistent with every full table scan
run in Phases 1 and 3 against a heap with zero indexes.
*/

-- ============================================================================
-- STEP 2: Confirm current index usage state (before making any change)
-- ============================================================================
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    s.user_seeks,
    s.user_scans,
    s.user_lookups
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s
    ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE OBJECT_NAME(i.object_id) = 'daily_observations';
GO

-- Result: daily_observations was a HEAP, 0 seeks, 7 scans - confirms every
-- query so far has done a full table scan, exactly as expected.

-- ============================================================================
-- STEP 3: Design decision - composite clustered index
-- ============================================================================
-- Real-world expected access pattern: queries always filter by station_id
-- AND obs_date together, not either column in isolation. This favors a
-- single composite index over Phase 1's two separate single-column missing-
-- index suggestions (station_id alone, obs_date alone) - with two separate
-- nonclustered indexes, SQL Server can only efficiently use one per query.
--
-- Column order: station_id first (132,501 distinct stations - high
-- cardinality, more selective), obs_date second (~1,095 possible dates
-- across 3 years - lower cardinality). Leading with the more selective
-- column gives better seek performance.
--
-- Made this the CLUSTERED index (not just nonclustered) since the table
-- was a heap and needed proper physical row ordering.
CREATE CLUSTERED INDEX CIX_daily_observations_station_date
ON climate.daily_observations (station_id, obs_date);
GO

-- Note: building this on 113.5 million rows took real time and rewrote the
-- table's entire physical storage - not an instant operation.

-- ============================================================================
-- STEP 4: Verify the index was created and confirm table is no longer a heap
-- ============================================================================
SELECT
    OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    s.user_seeks,
    s.user_scans,
    s.user_lookups
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats s
    ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE OBJECT_NAME(i.object_id) = 'daily_observations';
GO

-- Confirmed: CIX_daily_observations_station_date, type CLUSTERED

-- ============================================================================
-- STEP 5: Re-run Phase 1's Query 1 (station_id filter) - measure real impact
-- ============================================================================
-- Phase 1 baseline: 19,183 rows, 758,511 logical reads, scan count 9,
-- 1,658 ms elapsed, Table Scan + Parallelism.
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT *
FROM climate.daily_observations
WHERE station_id = 'USW00094728';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO

/*
RESULT - dramatic real improvement:
  - Logical reads:  758,511 -> 147        (~5,160x fewer)
  - Scan count:     9 -> 1                (parallel scan -> single seek)
  - Elapsed time:   1,658 ms -> 143 ms    (~11.6x faster)
  - Rows returned:  19,183 -> 19,183      (identical - confirms correctness)
  - Execution plan: Table Scan + Parallelism -> Clustered Index Seek
*/

-- ============================================================================
-- STEP 6: Re-run Phase 1's Query 2 (obs_date range filter) - measure impact
-- ============================================================================
-- Phase 1 baseline: 3,217,200 rows, 758,511 logical reads, scan count 9,
-- 17,371 ms elapsed, Table Scan + Parallelism.
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT *
FROM climate.daily_observations
WHERE obs_date BETWEEN '20230701' AND '20230731';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO

/*
RESULT - honest, non-improvement finding (documented as-is, not spun):
  - Logical reads:  758,511 -> 844,976    (slightly WORSE, +11.4%)
  - Scan count:     9 -> 9                (no change)
  - Elapsed time:   17,371 ms -> 17,056 ms (roughly flat, within noise)
  - Rows returned:  3,217,200 -> 3,217,200 (identical - confirms correctness)
  - Execution plan: Table Scan -> Clustered Index Scan (still a scan, not
    a seek - obs_date is the SECOND key in the composite index, so a query
    filtering on obs_date alone can't seek directly)

This confirms the exact trade-off anticipated when designing the index:
composite index leading with station_id dramatically helps "station_id"
and "station_id + obs_date" query patterns, but does NOT help an isolated
"obs_date alone" pattern. SQL Server's own missing-index suggestion here
recommended a separate nonclustered index on obs_date alone (70.8851%
estimated impact).
*/

-- ============================================================================
-- STEP 7: Design decision - do NOT add a supplementary obs_date index
-- ============================================================================
-- Followed a Brent Ozar-style philosophy here: the missing-index DMVs are
-- a hint, not a to-do list. They don't know the real workload, and they
-- don't account for the write-cost penalty every additional index adds
-- forever, on every future insert. The real-world expected access pattern
-- (confirmed with the user) is always "station_id + obs_date together" -
-- Phase 1's isolated date-range query was a synthetic baseline test, not
-- a representative real query.
--
-- Decision: do not add a nonclustered index on obs_date alone. If this
-- pattern turns out to matter in production, revisit with real evidence
-- from Phase 10's monitoring work (actual query patterns, not a one-off
-- synthetic test) - index based on proven need, not speculation.

/*
================================================================================
End of Phase 4 script.

Summary:
  - Wait stats baseline: CXPACKET/CXCONSUMER parallelism waits confirmed,
    consistent with heap table scans.
  - Confirmed daily_observations was a HEAP with 0 seeks, 7 scans before
    any change.
  - Created a composite CLUSTERED index on (station_id, obs_date), designed
    around the real expected access pattern rather than blindly applying
    Phase 1's two separate single-column missing-index suggestions.
  - Query 1 (station_id filter): dramatic real improvement - 758,511 ->
    147 logical reads, 1,658ms -> 143ms, Table Scan -> Clustered Index Seek.
  - Query 2 (obs_date range filter): honest non-improvement - 758,511 ->
    844,976 logical reads (slightly worse), Table Scan -> Clustered Index
    Scan (still not a seek, since obs_date isn't the leading key).
  - Deliberately declined to add a supplementary obs_date index, based on
    the real expected workload rather than a synthetic test result.

See docs/phase-4-performance-tuning.md for the full narrative write-up
and screenshots.
================================================================================
*/
