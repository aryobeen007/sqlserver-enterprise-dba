/*
================================================================================
Phase 2: Installation & Configuration
================================================================================
This script contains every T-SQL command I ran during Phase 2, in the order
I ran them. This phase verifies and extends the existing SQL Server 2025
install on SQLDBA-Primary from Project 1 - not a reinstall, just an audit
against configuration best practices and fixing what needed fixing.
================================================================================
*/

-- ============================================================================
-- STEP 1: Audit current server-level configuration
-- ============================================================================
-- Checked memory limits, MAXDOP, and cost threshold for parallelism -
-- the four settings most worth reviewing before touching anything else.
SELECT
    name,
    value,
    value_in_use,
    description
FROM sys.configurations
WHERE name IN (
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism'
)
ORDER BY name;
GO

/*
Findings from this audit:
  - cost threshold for parallelism = 5   -> factory default, too low for
    modern hardware. Common guidance is 25-50.
  - max degree of parallelism = 8        -> already correct, matches my
    8 vCPUs exactly. No change needed.
  - max server memory (MB) = 2147483647  -> this is SQL Server's "unlimited"
    default (max INT value). On a 16GB VM this risks starving the OS itself.
    Needed to be capped.
  - min server memory (MB) = 0 (value_in_use 16) -> negligible at these
    numbers, not worth changing.
*/

-- ============================================================================
-- STEP 2: Fix max server memory and cost threshold for parallelism
-- ============================================================================
-- Memory cap reasoning: 16GB VM total, leaving ~4GB headroom for the OS,
-- page file activity, and other Windows processes (Agent, monitoring, etc.)
-- gives 12GB (12000 MB) for SQL Server. Not an aggressive squeeze - a
-- standard safe starting point I can revisit in Phase 4 with real wait-stat
-- evidence if needed.
--
-- Cost threshold reasoning: raising from the decades-old default of 5 to 50
-- stops small, cheap queries from being parallelized unnecessarily.
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO

EXEC sp_configure 'max server memory (MB)', 12000;
GO

EXEC sp_configure 'cost threshold for parallelism', 50;
GO

RECONFIGURE;
GO

-- ============================================================================
-- STEP 3: Verify the changes took effect
-- ============================================================================
-- Confirmed: cost threshold 5 -> 50, max server memory unlimited -> 12000 MB
SELECT
    name,
    value,
    value_in_use
FROM sys.configurations
WHERE name IN (
    'max server memory (MB)',
    'cost threshold for parallelism'
)
ORDER BY name;
GO

-- ============================================================================
-- STEP 4: Verify TempDB configuration
-- ============================================================================
-- Checked file count, size, and growth settings against best practice
-- (one data file per CPU core, equal size, one log file, fixed-MB growth
-- rather than percentage-based).
SELECT
    name,
    physical_name,
    size / 128 AS size_MB,
    growth
FROM tempdb.sys.database_files;
GO

-- Confirmed growth type is fixed-MB, not percentage-based, across every file
SELECT
    name,
    growth,
    is_percent_growth
FROM tempdb.sys.database_files;
GO

/*
Findings: TempDB was already correctly configured from Project 1 - 8 equally
sized data files (72MB each) matching my 8 vCPUs, 1 log file, and fixed-MB
(not percentage) autogrowth on every file. No changes needed here - this is
a genuine "already correct" finding, not something I manufactured a fix for.
*/

-- ============================================================================
-- STEP 5: Verify authentication mode
-- ============================================================================
-- Confirms Mixed Mode (both SQL logins and Windows auth) is still active,
-- as deliberately configured in Project 1.
-- Returns 0 = Mixed Mode active, 1 = Windows Authentication only.
SELECT
    SERVERPROPERTY('IsIntegratedSecurityOnly') AS is_windows_auth_only;
GO

-- Result: 0 - Mixed Mode confirmed, no change needed.

/*
================================================================================
End of Phase 2 script.
Server-level configuration audited and corrected where needed:
  - max server memory: 2147483647 -> 12000 MB
  - cost threshold for parallelism: 5 -> 50
  - MAXDOP: verified correct at 8, no change
  - TempDB: verified correct (8 files, fixed-MB growth), no change
  - Authentication mode: verified Mixed Mode, no change
  - Core services (SQL Server, SQL Server Agent, SQL Server Browser):
    verified all Running via SQL Server Configuration Manager

See docs/phase-2-installation-configuration.md for the full narrative
write-up and screenshots.
================================================================================
*/
