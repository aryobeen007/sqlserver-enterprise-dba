/*
================================================================================
Phase 7: Auditing & Compliance
================================================================================
This script contains every T-SQL command I ran during Phase 7, in the order
I ran them. Covers: SQL Server Audit (server + database level), login
auditing, and Change Tracking - every piece tested with real evidence,
including an honest schema limitation I discovered and fixed along the way.
================================================================================
*/

-- ============================================================================
-- STEP 1: Create and enable a Server Audit
-- ============================================================================
USE master;
GO

-- NOTE: the C:\ClimateData\Audit\ folder had to exist inside the VM first -
-- SQL Server does not create the target folder automatically. My first
-- attempt failed with Msg 33072 (invalid audit log file path) until I
-- created the folder.
CREATE SERVER AUDIT climate_dba_audit
TO FILE (FILEPATH = 'C:\ClimateData\Audit\')
WITH (ON_FAILURE = CONTINUE);
GO

ALTER SERVER AUDIT climate_dba_audit
WITH (STATE = ON);
GO

-- Verified active. NOTE: my first verification query used status_desc and
-- audit_file_path column names, which don't exist on sys.server_audits
-- (Msg 207, invalid column name). Correct columns are name,
-- is_state_enabled, audit_guid.
SELECT
    name,
    is_state_enabled,
    audit_guid
FROM sys.server_audits
WHERE name = 'climate_dba_audit';
GO

-- ============================================================================
-- STEP 2: Create a Database Audit Specification
-- ============================================================================
-- Audits data changes (INSERT/UPDATE/DELETE) on the climate schema, plus
-- schema and permission changes - tracks who's modifying data and who's
-- changing security-relevant database structure.
USE climate_dba;
GO

CREATE DATABASE AUDIT SPECIFICATION climate_dba_audit_spec
FOR SERVER AUDIT climate_dba_audit
ADD (SCHEMA_OBJECT_CHANGE_GROUP),
ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
ADD (INSERT, UPDATE, DELETE ON SCHEMA::climate BY public)
WITH (STATE = ON);
GO

-- Verified active.
SELECT
    name,
    is_state_enabled
FROM sys.database_audit_specifications
WHERE name = 'climate_dba_audit_spec';
GO

-- ============================================================================
-- STEP 3: Verify auditing actually captures real events (not just configured)
-- ============================================================================
-- Made a real, identifiable test insert.
INSERT INTO climate.stations (station_id, latitude, longitude, elevation, state, station_name)
VALUES ('AUDITTEST1', '0.0', '0.0', '0', 'TS', 'PHASE7_AUDIT_TEST_MARKER');
GO

-- Confirmed the INSERT was captured with full statement text, timestamp,
-- and principal name.
SELECT
    event_time, action_id, succeeded, server_principal_name,
    database_name, object_name, statement
FROM sys.fn_get_audit_file('C:\ClimateData\Audit\*', DEFAULT, DEFAULT)
WHERE object_name = 'stations'
ORDER BY event_time DESC;
GO

-- Cleaned up the test row - and confirmed the DELETE itself was also
-- captured as a second real audit event.
DELETE FROM climate.stations WHERE station_id = 'AUDITTEST1';
GO

-- ============================================================================
-- STEP 4: Set up login auditing (successful + failed)
-- ============================================================================
USE master;
GO

CREATE SERVER AUDIT SPECIFICATION climate_login_audit_spec
FOR SERVER AUDIT climate_dba_audit
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP)
WITH (STATE = ON);
GO

-- Verified active.
SELECT
    name,
    is_state_enabled
FROM sys.server_audit_specifications
WHERE name = 'climate_login_audit_spec';
GO

-- Tested with a real successful login as climate_read_login - confirmed
-- multiple LGIS (Login Success) events captured with timestamp and
-- client_ip. NOTE: initially ran this verification query while still
-- connected AS climate_read_login by mistake, which correctly failed with
-- Msg 300 (VIEW SERVER SECURITY AUDIT permission denied) - climate_read_login
-- doesn't have permission to view the audit log, which is itself a
-- reasonable security boundary. Re-ran from my admin connection instead.
SELECT
    event_time, action_id, succeeded, server_principal_name, client_ip
FROM sys.fn_get_audit_file('C:\ClimateData\Audit\*', DEFAULT, DEFAULT)
WHERE server_principal_name = 'climate_read_login'
ORDER BY event_time DESC;
GO

-- Tested with a real FAILED login attempt (deliberately wrong password for
-- climate_read_login) - confirmed LGIF (Login Failed) events captured with
-- succeeded = 0.
SELECT
    event_time, action_id, succeeded, server_principal_name, client_ip
FROM sys.fn_get_audit_file('C:\ClimateData\Audit\*', DEFAULT, DEFAULT)
WHERE action_id = 'LGIF'
ORDER BY event_time DESC;
GO

-- ============================================================================
-- STEP 5: Enable Change Tracking at the database level
-- ============================================================================
ALTER DATABASE climate_dba
SET CHANGE_TRACKING = ON
(CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);
GO

-- ============================================================================
-- STEP 6: Enable Change Tracking on climate.stations
-- ============================================================================
-- Chose stations (132,501 rows) over daily_observations (113.5M rows) to
-- avoid unnecessary overhead - stations is sufficient to demonstrate the
-- mechanism.

-- First attempt failed: Msg 4997, Change Tracking requires a primary key,
-- and stations was deliberately built with none back in Phase 1.
--
-- Fixed properly (not a workaround - station_id is a genuine natural key):
-- first had to make the column NOT NULL, since a primary key requires
-- non-null values (Msg 8111 on the first PK attempt). Confirmed no existing
-- NULLs before this succeeded.
ALTER TABLE climate.stations
ALTER COLUMN station_id VARCHAR(11) NOT NULL;
GO

ALTER TABLE climate.stations
ADD CONSTRAINT PK_stations PRIMARY KEY (station_id);
GO

-- Verified the primary key genuinely exists (a later "add it again" attempt
-- correctly errored with Msg 1779, confirming it already succeeded on this
-- first try, even though the earlier session's success message was unclear).
SELECT
    kc.name AS constraint_name,
    c.name AS column_name
FROM sys.key_constraints kc
JOIN sys.index_columns ic ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE kc.parent_object_id = OBJECT_ID('climate.stations');
GO

-- Now Change Tracking could be enabled successfully.
ALTER TABLE climate.stations
ENABLE CHANGE_TRACKING
WITH (TRACK_COLUMNS_UPDATED = ON);
GO

-- Verified active with column-level tracking.
SELECT
    OBJECT_NAME(object_id) AS table_name,
    is_track_columns_updated_on
FROM sys.change_tracking_tables
WHERE object_id = OBJECT_ID('climate.stations');
GO

-- ============================================================================
-- STEP 7: Verify Change Tracking captures a real row-level change
-- ============================================================================
SELECT CHANGE_TRACKING_CURRENT_VERSION() AS current_version;
GO
-- Baseline version: 0

UPDATE climate.stations
SET station_name = 'CHANGE_TRACKING_TEST_UPDATE'
WHERE station_id = 'ACW00011604';
GO

-- Confirmed: version incremented to 1, operation 'U' (Update), correct
-- station_id.
SELECT
    SYS_CHANGE_VERSION,
    SYS_CHANGE_OPERATION,
    station_id
FROM CHANGETABLE(CHANGES climate.stations, 0) AS CT
ORDER BY SYS_CHANGE_VERSION DESC;
GO

-- Reverted the test change to leave data clean.
UPDATE climate.stations
SET station_name = 'ST JOHNS COOLIDGE FLD'
WHERE station_id = 'ACW00011604';
GO

/*
================================================================================
End of Phase 7 script.

Summary:
  - Server Audit + Database Audit Specification: verified capturing real
    INSERT and DELETE events with full statement text and principal name.
  - Login auditing: verified capturing both successful (LGIS) and failed
    (LGIF) login attempts with timestamp and client IP.
  - Change Tracking: discovered a genuine schema limitation (stations had
    no primary key, by design from Phase 1) - fixed properly by adding a
    real primary key on station_id, then verified Change Tracking captures
    real row-level UPDATE operations.

See docs/phase-7-auditing-compliance.md for the full narrative write-up
and screenshots.
================================================================================
*/
