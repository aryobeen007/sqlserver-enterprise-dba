/*
================================================================================
Phase 1: New Database - Sourcing, Schema & Baseline
================================================================================
This script contains every T-SQL command I ran during Phase 1, in the order
I ran them. Covers: database/schema creation, table creation (deliberately
unoptimized), bulk loading the NOAA GHCN-Daily dataset, and baseline
diagnostic queries against the unindexed schema.

Dataset: NOAA GHCN-Daily (2021-2023 daily observations + station metadata)
Source: https://noaa-ghcn-pds.s3.amazonaws.com/csv/by_year/
================================================================================
*/

-- ============================================================================
-- STEP 1: Create the new database
-- ============================================================================
-- Kept separate from healthcare_dba (Project 1) on purpose - this project
-- needs its own fresh, deliberately unoptimized dataset to diagnose later.
CREATE DATABASE climate_dba;
GO

USE climate_dba;
GO

-- ============================================================================
-- STEP 2: Create the climate schema
-- ============================================================================
-- Mirrors the cms/audit schema pattern from Project 1.
CREATE SCHEMA climate;
GO

-- ============================================================================
-- STEP 3: Create climate.stations table (deliberately unoptimized)
-- ============================================================================
-- No primary key, no proper numeric types for lat/long/elevation -
-- matches what a rushed first-pass load would actually look like.
CREATE TABLE climate.stations (
    station_id      VARCHAR(11),
    latitude        VARCHAR(20),
    longitude       VARCHAR(20),
    elevation       VARCHAR(20),
    state           VARCHAR(10),
    station_name    VARCHAR(100)
);
GO

-- ============================================================================
-- STEP 4: Create climate.daily_observations table (deliberately unoptimized)
-- ============================================================================
-- No primary key, no foreign key to climate.stations, no indexes on the
-- columns I'll obviously query on (station_id, obs_date). Dates stored as
-- text instead of a real DATE type. This is my "before" state for Phase 4.
CREATE TABLE climate.daily_observations (
    station_id      VARCHAR(11),
    obs_date        VARCHAR(8),
    element         VARCHAR(4),
    data_value      VARCHAR(10),
    m_flag          VARCHAR(1),
    q_flag          VARCHAR(1),
    s_flag          VARCHAR(1),
    obs_time        VARCHAR(4)
);
GO

-- ============================================================================
-- STEP 5: Load station metadata (fixed-width file)
-- ============================================================================
-- ghcnd-stations.txt is a fixed-width file, not comma-delimited, so I load
-- it into a staging table as raw text lines first, then parse it below.
CREATE TABLE climate.stations_staging (
    raw_line VARCHAR(1000)  -- widened from my first attempt (500) after
                            -- hitting a "column too long" error
);
GO

-- NOTE: My first two attempts at this BULK INSERT failed on ROWTERMINATOR.
--   Attempt 1: ROWTERMINATOR = '\n'    -> failed ("column too long")
--   Attempt 2: ROWTERMINATOR = '\r\n'  -> failed (same error)
-- Root cause: T-SQL does NOT interpret '\n' as an escape sequence - it reads
-- it as two literal characters (backslash + "n"), not a newline. I confirmed
-- via PowerShell byte inspection that the file actually uses bare line feeds
-- (0x0A). The fix was using the hex literal instead of a string literal:
BULK INSERT climate.stations_staging
FROM 'C:\ClimateData\ghcnd-stations.txt'
WITH (
    ROWTERMINATOR = '0x0a',
    CODEPAGE = 'RAW'
);
GO

-- Confirm staging load - expected ~132,501 rows (matches NOAA's documented
-- station count worldwide)
SELECT COUNT(*) AS total_rows FROM climate.stations_staging;
GO

-- ============================================================================
-- STEP 6: Parse fixed-width staging data into climate.stations
-- ============================================================================
-- Column positions confirmed from NOAA's ghcnd-stations.txt format spec:
--   ID          columns 1-11
--   LATITUDE    columns 13-20
--   LONGITUDE   columns 22-30
--   ELEVATION   columns 32-37
--   STATE       columns 39-40
--   NAME        columns 42-71
INSERT INTO climate.stations (station_id, latitude, longitude, elevation, state, station_name)
SELECT
    LTRIM(RTRIM(SUBSTRING(raw_line, 1, 11)))   AS station_id,
    LTRIM(RTRIM(SUBSTRING(raw_line, 13, 8)))   AS latitude,
    LTRIM(RTRIM(SUBSTRING(raw_line, 22, 9)))   AS longitude,
    LTRIM(RTRIM(SUBSTRING(raw_line, 32, 6)))   AS elevation,
    LTRIM(RTRIM(SUBSTRING(raw_line, 39, 2)))   AS state,
    LTRIM(RTRIM(SUBSTRING(raw_line, 42, 30)))  AS station_name
FROM climate.stations_staging;
GO

-- Verify parse - row count should match staging table exactly (132,501)
SELECT COUNT(*) AS total_rows FROM climate.stations;
GO

SELECT TOP 5 * FROM climate.stations;
GO

-- ============================================================================
-- STEP 7: Bulk-load daily observations (comma-delimited CSVs)
-- ============================================================================
-- Checked the raw bytes of 2023.csv first (same way as the stations file) -
-- confirmed same 0x0A line ending, and discovered these files DO have a
-- header row (ID,DATE,ELEMENT,DATA_VALUE,M_FLAG,Q_FLAG,S_FLAG,OBS_TIME),
-- which NOAA's own docs didn't make obvious. FIRSTROW = 2 skips it.

-- Load 2023 first to confirm the approach works before doing all three years
BULK INSERT climate.daily_observations
FROM 'C:\ClimateData\2023.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    FIRSTROW = 2,
    CODEPAGE = 'RAW'
);
GO

-- Confirmed 37,907,983 rows for 2023 alone before proceeding
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;
GO

-- Load remaining two years
BULK INSERT climate.daily_observations
FROM 'C:\ClimateData\2022.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    FIRSTROW = 2,
    CODEPAGE = 'RAW'
);
GO

BULK INSERT climate.daily_observations
FROM 'C:\ClimateData\2021.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    FIRSTROW = 2,
    CODEPAGE = 'RAW'
);
GO

-- Final confirmed total across all three years: 113,522,932 rows
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;
GO

-- ============================================================================
-- STEP 8: Baseline diagnostics - run against the unindexed schema as-is
-- ============================================================================
-- The whole point of Phase 1 is to establish honest, reproducible "before"
-- numbers I can come back and improve in Phase 4. No indexes exist yet on
-- station_id or obs_date, so both queries below force full table scans.

-- --- Query 1: filter by station_id -----------------------------------------
-- Result: 19,183 rows, 758,511 logical reads, scan count 9 (parallel scan),
-- 1.658s elapsed. SQL Server's own missing-index suggestion recommended a
-- nonclustered index on station_id (99.5% estimated impact).
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT *
FROM climate.daily_observations
WHERE station_id = 'USW00094728';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO

-- --- Query 2: filter by date range -----------------------------------------
-- Result: 3,217,200 rows, 758,511 logical reads (identical I/O cost to
-- Query 1, since both scan the whole table regardless of filter column),
-- 17.371s elapsed (slower than Query 1, likely due to returning far more
-- rows to the client). SQL Server suggested a nonclustered index on
-- obs_date (68.3% estimated impact) - a different recommendation than
-- Query 1, which is realistic: I'll need to reconcile both in Phase 4.
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

SELECT *
FROM climate.daily_observations
WHERE obs_date BETWEEN '20230701' AND '20230731';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
GO

/*
================================================================================
End of Phase 1 script.
Baseline established: 113,522,932 rows loaded, zero indexes, two documented
full-scan queries with real STATISTICS TIME/IO numbers and execution plans.
See docs/phase-1-new-database.md for the full narrative write-up and
screenshots.
================================================================================
*/
