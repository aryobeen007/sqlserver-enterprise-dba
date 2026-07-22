/* ================================================================
   PHASE 10 — MONITORING
   Database: climate_dba
   Server:   SQLDBA-SECNDRY (192.168.1.214) — current AG PRIMARY as of Phase 9
   ================================================================
   Goal: build a DMV-based monitoring query set (session / query / wait
   level) and an Extended Events session covering deadlocks and
   long-running queries, then prove both actually catch a real event
   rather than just existing on paper.
   ================================================================ */


-- ================================================================
-- SECTION 1: SESSION-LEVEL MONITORING (baseline)
-- ================================================================
-- Purpose: who/what is connected right now, and how expensive has
-- each session been (CPU, reads/writes, last activity).
SELECT
    session_id,
    login_name,
    host_name,
    program_name,
    status,
    cpu_time,
    memory_usage,
    reads,
    writes,
    logical_reads,
    last_request_start_time,
    last_request_end_time
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
ORDER BY cpu_time DESC;

-- Result: mostly my own SSMS sessions plus SQL Server Agent's job
-- invocation engine (visible firing at 08:40:00, matching the
-- Climate_DBA_Log_Backup job's 5-minute schedule). Nothing unexpected.


-- ================================================================
-- SECTION 2: QUERY-LEVEL MONITORING (top resource consumers)
-- ================================================================
-- Purpose: which cached query plans have consumed the most CPU
-- since the instance last started, with the actual SQL text resolved.
SELECT TOP 10
    qs.execution_count,
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
    qs.total_elapsed_time / 1000 AS total_elapsed_ms,
    qs.last_execution_time,
    SUBSTRING(st.text, (qs.statement_start_offset/2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_worker_time DESC;

-- Real result: the #1 consumer by a wide margin was
--     SELECT COUNT(*) AS total_rows FROM climate.daily_observations
-- 2 executions, ~7,413ms avg CPU, ~861,329 avg logical reads.
-- This is expected, not a problem: no WHERE clause means the
-- composite clustered index on (station_id, obs_date) can't be
-- used for a seek, so it's a full scan of all 113,522,932 rows
-- (consistent with the Phase 4 finding that isolated/no-predicate
-- access on this table is a deliberate, documented full-scan case).
-- Everything else in the top 10 was SSMS Object Explorer / IntelliSense
-- background queries — useful confirmation that this DMV cleanly
-- separates real workload from tooling noise.


-- ================================================================
-- SECTION 3: RESOURCE-LEVEL MONITORING (wait stats)
-- ================================================================
-- Purpose: what has SQL Server actually spent time waiting on,
-- filtered down from ~1,000+ wait types to the ones that matter.
SELECT TOP 15
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK',
    'SLEEP_SYSTEMTASK','SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE',
    'CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT',
    'BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
    'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
    'XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN','SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'BROKER_EVENTHANDLER','TRACEWRITE','BROKER_RECEIVE_WAITFOR',
    'ONDEMAND_TASK_QUEUE','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'SP_SERVER_DIAGNOSTICS_SLEEP'
)
ORDER BY wait_time_ms DESC;

-- Real finding worth calling out: HADR_SYNC_COMMIT (5,343,394 ms across
-- 26,478 waits), plus HADR_WORK_QUEUE / HADR_TIMER_TASK /
-- HADR_NOTIFICATION_DEQUEUE, are all Always On AG replication overhead.
-- This is the actual measurable cost of running synchronous-commit AG
-- in this environment, not noise — ties directly back to the Phase 9
-- Always On setup. VDI_CLIENT_OTHER lines up with the constant backup
-- job activity (5-minute log backups use VDI). QDS_* entries are Query
-- Store's own background housekeeping.


-- ================================================================
-- SECTION 4: EXTENDED EVENTS SESSION — deadlocks + long-running queries
-- ================================================================
-- Purpose: catch two specific classes of event as they happen, rather
-- than relying on someone noticing after the fact.
CREATE EVENT SESSION [ClimateDBA_Monitoring] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report,
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(sqlserver.sql_text, sqlserver.session_id, sqlserver.username, sqlserver.database_name)
    WHERE ([sqlserver].[database_name] = N'climate_dba' AND duration > 1000000)  -- microseconds; > 1 second
)
ADD TARGET package0.event_file(
    SET filename = N'C:\ClimateData\ClimateDBA_Monitoring.xel',
    max_file_size = 50,
    max_rollover_files = 5
)
WITH (MAX_MEMORY = 4096 KB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, MAX_DISPATCH_LATENCY = 5 SECONDS);
GO

ALTER EVENT SESSION [ClimateDBA_Monitoring] ON SERVER STATE = START;
GO


-- ================================================================
-- SECTION 5: VERIFY THE SESSION IS ACTUALLY RUNNING
-- ================================================================
SELECT
    s.name AS session_name,
    s.create_time,
    t.target_name,
    CAST(t.target_data AS XML).value('(EventFileTarget/File/@name)[1]', 'nvarchar(260)') AS file_name
FROM sys.dm_xe_sessions s
JOIN sys.dm_xe_session_targets t ON s.address = t.event_session_address
WHERE s.name = 'ClimateDBA_Monitoring';

-- Confirmed active, writing to:
-- C:\ClimateData\ClimateDBA_Monitoring_0_134292088095250000.xel


-- ================================================================
-- SECTION 6: FIRST ATTEMPT TO PROVE LONG-QUERY CAPTURE — RESULT: EMPTY
-- ================================================================
-- Real troubleshooting note, documented honestly (not swept under the
-- rug): I re-ran the same full-scan query expecting it to exceed the
-- 1-second threshold again:
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;

-- Then read the XE file target:
SELECT
    event_data.value('(event/@name)[1]', 'varchar(50)') AS event_name,
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS event_time,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS duration_seconds,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
    event_data.value('(event/action[@name="username"]/value)[1]', 'nvarchar(100)') AS username
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file(
        'C:\ClimateData\ClimateDBA_Monitoring*.xel', NULL, NULL, NULL
    )
) AS x
WHERE event_data.value('(event/@name)[1]', 'varchar(50)') = 'sql_statement_completed'
ORDER BY event_time DESC;

-- Result: 0 rows. Not a bug in the session — diagnosed in Section 7.


-- ================================================================
-- SECTION 7: DIAGNOSING THE EMPTY RESULT
-- ================================================================
-- Checked the query's actual last-execution elapsed time (not the
-- cumulative average, which was still skewed by the original cold run):
SELECT
    qs.execution_count,
    qs.last_elapsed_time / 1000.0 AS last_elapsed_ms,
    qs.last_worker_time / 1000.0 AS last_cpu_ms,
    qs.last_execution_time,
    st.text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.text LIKE '%daily_observations%' AND st.text LIKE '%COUNT%';

-- Real finding: the standalone re-run completed in 748.57ms elapsed —
-- UNDER the 1-second threshold. The first run (cold cache, right after
-- the instance/session started paying attention) took ~5.9-7.4s because
-- it had to physically read 113.5M rows' worth of pages from disk.
-- By the second/third run, the buffer pool had those pages cached in
-- memory, so the identical full scan got ~10x faster. This is genuine
-- buffer-cache behavior, not a flaw in the monitoring setup — but it
-- meant I needed a real cold-cache condition to prove the XE session
-- actually fires.


-- ================================================================
-- SECTION 8: FORCING A GENUINE COLD-CACHE RUN
-- ================================================================
-- DBCC DROPCLEANBUFFERS is a standard DBA technique for reproducing
-- cold-cache behavior in non-production environments. Used here
-- deliberately and only in this lab, never on a live production system.
DBCC DROPCLEANBUFFERS;
GO
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;
GO


-- ================================================================
-- SECTION 9: VERIFYING CAPTURE — SUCCESS
-- ================================================================
SELECT
    event_data.value('(event/@name)[1]', 'varchar(50)') AS event_name,
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS event_time,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS duration_seconds,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
    event_data.value('(event/action[@name="username"]/value)[1]', 'nvarchar(100)') AS username
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file(
        'C:\ClimateData\ClimateDBA_Monitoring*.xel', NULL, NULL, NULL
    )
) AS x
WHERE event_data.value('(event/@name)[1]', 'varchar(50)') = 'sql_statement_completed'
ORDER BY event_time DESC;

-- Real captured row:
-- event_time: 2026-07-22 15:52:14.792 | duration_seconds: 1.707253
-- sql_text: SELECT COUNT(*) AS total_rows FROM climate.daily_observations;
-- username: SQLDBA-SECNDRY\Administrator
-- See screenshot 71-xe-session-captured-slow-query.png


-- ================================================================
-- SECTION 10: DEADLOCK TEST — deliberately inducing a real deadlock
-- ================================================================
-- Setup (run in a SECOND SSMS query window):
USE climate_dba;
GO
IF OBJECT_ID('dbo.deadlock_test_a') IS NOT NULL DROP TABLE dbo.deadlock_test_a;
IF OBJECT_ID('dbo.deadlock_test_b') IS NOT NULL DROP TABLE dbo.deadlock_test_b;
CREATE TABLE dbo.deadlock_test_a (id INT PRIMARY KEY, val INT);
CREATE TABLE dbo.deadlock_test_b (id INT PRIMARY KEY, val INT);
INSERT INTO dbo.deadlock_test_a VALUES (1, 100);
INSERT INTO dbo.deadlock_test_b VALUES (1, 200);
GO

-- Window 2 opens a transaction and locks table A, deliberately left open:
BEGIN TRAN;
UPDATE dbo.deadlock_test_a SET val = 999 WHERE id = 1;
-- (transaction intentionally left uncommitted at this point)

-- Window 1 (first SSMS window) then locks table B, then tries to lock
-- table A — blocks, because window 2 already holds that lock:
BEGIN TRAN;
UPDATE dbo.deadlock_test_b SET val = 888 WHERE id = 1;
UPDATE dbo.deadlock_test_a SET val = 777 WHERE id = 1;  -- hangs here

-- Back in window 2, closing the cycle by trying to lock table B
-- (which window 1 now holds) creates the circular wait:
UPDATE dbo.deadlock_test_b SET val = 111 WHERE id = 1;

-- Real result: within a few seconds, SQL Server's deadlock monitor
-- detected the cycle and killed window 2's transaction as the victim:
--   Msg 1205, Level 13, State 51, Line 14
--   Transaction (Process ID 72) was deadlocked on lock resources with
--   another process and has been chosen as the deadlock victim.
--   Rerun the transaction.
-- Window 1's blocked UPDATE then completed normally once the lock
-- was released.

-- Cleanup (surviving transaction + test objects):
COMMIT;
GO
IF OBJECT_ID('dbo.deadlock_test_a') IS NOT NULL DROP TABLE dbo.deadlock_test_a;
IF OBJECT_ID('dbo.deadlock_test_b') IS NOT NULL DROP TABLE dbo.deadlock_test_b;
GO


-- ================================================================
-- SECTION 11: PULLING THE CAPTURED DEADLOCK GRAPH
-- ================================================================
SELECT
    event_data.value('(event/@name)[1]', 'varchar(50)') AS event_name,
    event_data.value('(event/@timestamp)[1]', 'datetime2') AS event_time,
    event_data.query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file(
        'C:\ClimateData\ClimateDBA_Monitoring*.xel', NULL, NULL, NULL
    )
) AS x
WHERE event_data.value('(event/@name)[1]', 'varchar(50)') = 'xml_deadlock_report'
ORDER BY event_time DESC;

-- Real captured graph confirmed:
--   victim: process (SPID 72)
--   process 72: waitresource KEY on climate_dba.dbo.deadlock_test_b,
--               inputbuf = UPDATE dbo.deadlock_test_b SET val = 111 WHERE id = 1;
--   process 76: waitresource KEY on climate_dba.dbo.deadlock_test_a,
--               inputbuf = BEGIN TRAN; UPDATE dbo.deadlock_test_b SET val = 888...;
--                          UPDATE dbo.deadlock_test_a SET val = 777 WHERE id = 1;
--   resource-list confirms the classic circular wait:
--     lock on deadlock_test_b: owned by process 76, waited on by process 72
--     lock on deadlock_test_a: owned by process 72, waited on by process 76
-- See screenshot 72-xe-deadlock-graph-captured.png
-- (Full raw XML, including binary stack-frame debug info, preserved in
-- the .xel file itself; trimmed here to the parts that tell the story.)


-- ================================================================
-- END OF PHASE 10
-- ================================================================
-- Known limitation carried forward unchanged from earlier phases:
-- Database Mail is still not configured in this lab (no real SMTP
-- server available), so none of this monitoring pushes alerts by
-- email — it's pull-based (someone has to run these queries or read
-- the .xel file). Documented as a real constraint, not silently fixed.
