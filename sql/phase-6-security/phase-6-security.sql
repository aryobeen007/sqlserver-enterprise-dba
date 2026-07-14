/*
================================================================================
Phase 6: Security
================================================================================
This script contains every T-SQL command I ran during Phase 6, in the order
I ran them. Covers: least-privilege role model with real logins, Transparent
Data Encryption, Row-Level Security, and Dynamic Data Masking - every piece
tested with real evidence, not just configured and assumed to work.

NOTE ON CREDENTIALS: every password below is a placeholder. Real passwords
were used locally when I actually ran this script and were never committed
to source control. Replace <STRONG_PASSWORD_HERE> with real, unique values
before running this yourself.
================================================================================
*/

USE climate_dba;
GO

-- ============================================================================
-- STEP 1: Audit current security state before designing anything
-- ============================================================================
SELECT
    dp.name AS principal_name,
    dp.type_desc,
    dp.authentication_type_desc
FROM sys.database_principals dp
WHERE dp.type NOT IN ('R')
AND dp.name NOT LIKE '##%'
ORDER BY dp.name;
GO

-- Result: only built-in principals (dbo, guest, INFORMATION_SCHEMA, sys)
-- existed - confirms security was being designed from scratch.

-- ============================================================================
-- STEP 2: Create SQL logins (server-level)
-- ============================================================================
CREATE LOGIN climate_read_login WITH PASSWORD = '<STRONG_PASSWORD_HERE>', CHECK_POLICY = ON;
CREATE LOGIN climate_write_login WITH PASSWORD = '<STRONG_PASSWORD_HERE>', CHECK_POLICY = ON;
CREATE LOGIN climate_admin_login WITH PASSWORD = '<STRONG_PASSWORD_HERE>', CHECK_POLICY = ON;
GO

-- ============================================================================
-- STEP 3: Create database users mapped to those logins
-- ============================================================================
CREATE USER climate_read_user FOR LOGIN climate_read_login;
CREATE USER climate_write_user FOR LOGIN climate_write_login;
CREATE USER climate_admin_user FOR LOGIN climate_admin_login;
GO

-- ============================================================================
-- STEP 4: Create custom database roles - least-privilege model
-- ============================================================================
CREATE ROLE climate_readonly;
CREATE ROLE climate_readwrite;
CREATE ROLE climate_admin;
GO

-- Grant permissions scoped to the climate schema only.
GRANT SELECT ON SCHEMA::climate TO climate_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::climate TO climate_readwrite;
GO

-- NOTE: CREATE TABLE cannot be scoped to a schema via GRANT ... ON SCHEMA::
-- (it's a database-level permission, not object-level) - this was a real
-- error I hit on my first attempt (Msg 102, incorrect syntax) and had to
-- split into two separate GRANT statements.
GRANT SELECT, INSERT, UPDATE, DELETE, ALTER ON SCHEMA::climate TO climate_admin;
GRANT CREATE TABLE TO climate_admin;
GO

-- Add users to their respective roles.
ALTER ROLE climate_readonly ADD MEMBER climate_read_user;
ALTER ROLE climate_readwrite ADD MEMBER climate_write_user;
ALTER ROLE climate_admin ADD MEMBER climate_admin_user;
GO

-- Verified role membership mapped correctly.
SELECT
    dp.name AS role_name,
    mp.name AS member_name
FROM sys.database_role_members drm
JOIN sys.database_principals dp ON drm.role_principal_id = dp.principal_id
JOIN sys.database_principals mp ON drm.member_principal_id = mp.principal_id
WHERE dp.name IN ('climate_readonly', 'climate_readwrite', 'climate_admin')
ORDER BY role_name;
GO

-- ============================================================================
-- STEP 5: Verify the read-only role genuinely cannot write (real test)
-- ============================================================================
EXECUTE AS LOGIN = 'climate_read_login';

-- Succeeded - returned 5 real rows.
SELECT TOP 5 * FROM climate.stations;

-- Failed as expected: Msg 229, INSERT permission denied.
INSERT INTO climate.stations (station_id, latitude, longitude, elevation, state, station_name)
VALUES ('SHOULDFAIL', '0', '0', '0', 'XX', 'PERMISSION_TEST');

REVERT;
GO

-- ============================================================================
-- STEP 6: Transparent Data Encryption (TDE)
-- ============================================================================
USE master;
GO

-- Master key must be created in master, not the user database.
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<STRONG_PASSWORD_HERE>';
GO

-- Certificate protected by the master key.
CREATE CERTIFICATE climate_dba_tde_cert
WITH SUBJECT = 'Certificate for climate_dba TDE';
GO

-- CRITICAL: backed up the certificate and private key immediately. Losing
-- this certificate without a backup means permanently losing access to the
-- encrypted database, even with full database backups (which would also be
-- encrypted and unreadable without this certificate).
BACKUP CERTIFICATE climate_dba_tde_cert
TO FILE = 'C:\ClimateData\climate_dba_tde_cert.cer'
WITH PRIVATE KEY (
    FILE = 'C:\ClimateData\climate_dba_tde_cert.pvk',
    ENCRYPTION BY PASSWORD = '<ANOTHER_STRONG_PASSWORD_HERE>'
);
GO

USE climate_dba;
GO

-- Create the Database Encryption Key, protected by the certificate.
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE climate_dba_tde_cert;
GO

-- Turn encryption on. Took real time given the ~7GB database size.
ALTER DATABASE climate_dba
SET ENCRYPTION ON;
GO

-- Verified encryption state - checked twice, since the first check showed
-- encryption_state = 2 (In Progress) at 48.47% complete, not yet finished.
SELECT
    db.name AS database_name,
    dek.encryption_state,
    dek.percent_complete,
    dek.key_algorithm,
    dek.key_length
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases db ON dek.database_id = db.database_id
WHERE db.name = 'climate_dba';
GO

-- Final result: encryption_state = 3 (Encrypted), percent_complete = 0,
-- AES-256. TDE genuinely active.

-- ============================================================================
-- STEP 7: Row-Level Security (RLS)
-- ============================================================================
-- Scenario: restrict climate_read_user to only see CA stations - simulating
-- a regional analyst who should only access their assigned region's data.

-- Confirmed the real CA station count first, to verify the policy against
-- afterward: 3,241 CA stations out of 132,501 total.
SELECT COUNT(*) AS ca_station_count
FROM climate.stations
WHERE state = 'CA';
GO

CREATE SCHEMA Security;
GO

-- Security predicate function: returns a row (allows access) only when
-- state = 'CA', or when the querying user is dbo (admin bypass).
CREATE FUNCTION Security.fn_state_predicate(@state VARCHAR(10))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS fn_result
    WHERE @state = 'CA'
       OR USER_NAME() = 'dbo';
GO

-- Attach the predicate to the table and turn the policy on.
CREATE SECURITY POLICY climate_state_filter_policy
ADD FILTER PREDICATE Security.fn_state_predicate(state)
ON climate.stations
WITH (STATE = ON);
GO

-- Verified: climate_read_login sees only 3,241 rows (CA-only), not the
-- full 132,501 - real, working row-level filtering.
EXECUTE AS LOGIN = 'climate_read_login';
SELECT COUNT(*) AS visible_stations FROM climate.stations;
REVERT;
GO

-- Verified the bypass condition too: admin context still sees all 132,501.
SELECT COUNT(*) AS visible_stations FROM climate.stations;
GO

-- ============================================================================
-- STEP 8: Dynamic Data Masking
-- ============================================================================
-- Masked latitude/longitude - treating precise station coordinates as
-- sensitive location data that lower-privilege users shouldn't see in
-- full precision.
ALTER TABLE climate.stations
ALTER COLUMN latitude ADD MASKED WITH (FUNCTION = 'default()');

ALTER TABLE climate.stations
ALTER COLUMN longitude ADD MASKED WITH (FUNCTION = 'default()');
GO

-- Verified: climate_read_login sees 'xxxx' for latitude/longitude, while
-- station_id and station_name remain visible normally. (Result set also
-- confirmed RLS still filtering correctly alongside masking - all rows
-- shown were CA stations.)
EXECUTE AS LOGIN = 'climate_read_login';
SELECT TOP 5 station_id, latitude, longitude, station_name
FROM climate.stations;
REVERT;
GO

-- Verified admin context sees real, unmasked coordinate values.
SELECT TOP 5 station_id, latitude, longitude, station_name
FROM climate.stations;
GO

/*
================================================================================
End of Phase 6 script.

Summary:
  - Least-privilege role model: 3 roles (readonly/readwrite/admin), 3 real
    logins/users, tested and verified - read-only role genuinely denied
    INSERT with Msg 229.
  - TDE: fully enabled and verified active (AES-256, encryption_state = 3).
    Certificate backed up immediately - losing it without backup would mean
    permanently losing access to the encrypted database.
  - Row-Level Security: verified restricting climate_read_login to 3,241
    CA-only stations, while admin bypass correctly still sees all 132,501.
  - Dynamic Data Masking: verified hiding lat/long from climate_read_login
    while admin sees real values.

See docs/phase-6-security.md for the full narrative write-up and
screenshots.
================================================================================
*/
