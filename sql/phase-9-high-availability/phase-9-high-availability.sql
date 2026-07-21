/*
================================================================================
Phase 9: High Availability (Always On Availability Groups)
================================================================================
This script contains every T-SQL and PowerShell command I ran during Phase 9,
in the order I ran them. This was the most challenging phase of the project -
covers provisioning a secondary replica VM, real network/authentication
troubleshooting, building the Availability Group, and a manual failover test
that genuinely hit a split-brain scenario before being resolved.

IMPORTANT SCOPE DECISION: I chose CLUSTER_TYPE = NONE for this Availability
Group rather than a real Windows Server Failover Cluster (WSFC). This was
deliberate: both VMs are standalone workgroup machines, not domain-joined.
Setting up a domain controller + WSFC would have been a multi-hour
undertaking (estimated 4-8 hours) on top of everything else in this project.
In a REAL PRODUCTION ENVIRONMENT, a proper WSFC with Active Directory is
strongly recommended - it provides quorum-based arbitration that prevents
the exact split-brain scenario I hit later in this phase, plus automatic
failover support. CLUSTER_TYPE = NONE only supports manual/forced failover
and carries real split-brain risk, as I discovered firsthand.
================================================================================
*/

-- ============================================================================
-- STEP 1: Confirm baseline state before building anything
-- ============================================================================
SELECT
    SERVERPROPERTY('ProductVersion') AS sql_version,
    SERVERPROPERTY('Edition') AS edition,
    SERVERPROPERTY('IsHadrEnabled') AS hadr_enabled;
GO
-- Confirmed: SQL Server 2025 (17.0.1000.7), Enterprise Developer Edition,
-- hadr_enabled = 0 (not yet configured).

/*
================================================================================
VM PROVISIONING (PowerShell, run on the HOST machine)
================================================================================
Built SQLDBA-Secondary via Hyper-V Manager wizard first: Generation 2,
4096MB startup memory with Dynamic Memory (4096MB min, 16384MB max, matching
Primary), 80GB VHDX, connected to SQLLab-External-Switch, Guest Services
enabled.

REAL PROBLEM #1: Could not boot Windows Server installer from the attached
ISO. Hit "The boot loader failed" on SCSI DVD repeatedly, across many
attempts (cold boots, boot order changes, disabling Secure Boot, moving the
ISO to a fresh folder to rule out permissions). Verified the ISO itself was
completely healthy (correct size ~7.6GB, mounted cleanly on the host,
contained valid boot/efi/sources/setup.exe files) - the problem was
specifically in how Hyper-V Gen 2 UEFI handled this particular Windows
Server 2025 evaluation ISO. This is a documented, known issue (confirmed via
web search - other users hit the identical symptom with this exact ISO).

DECISION: rather than keep fighting the ISO boot issue, I cloned
SQLDBA-Primary instead via Hyper-V export/import - avoiding the ISO boot
path entirely since the clone already has Windows + SQL Server installed.
*/

-- (PowerShell, on host - cleaned up the broken VM first)
-- Stop-VM -Name "SQLDBA-Secondary" -Force
-- Remove-VM -Name "SQLDBA-Secondary" -Force
-- Remove-Item "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\SQLDBA-Secondary.vhdx" -Force

-- (PowerShell, on host - exported Primary, then imported as a new VM)
-- Export-VM -Name "SQLDBA-Primary" -Path "C:\VM-Export"
-- Import-VM -Path "C:\VM-Export\SQLDBA-Primary\Virtual Machines\<vmcx file>" -Copy -GenerateNewId -VirtualMachinePath "C:\ProgramData\Microsoft\Windows\Hyper-V" -VhdDestinationPath "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks"
-- Get-VM -Id <new VM's GUID> | Rename-VM -NewName "SQLDBA-Secondary"

/*
Post-clone cleanup needed:
  - Removed the stale DVD drive reference (pointed at an ISO path Hyper-V's
    service account couldn't access) - required discarding the VM's "Saved"
    state first (Stop-VM -Force) since hardware can't be modified while saved.
  - Get-VMDvdDrive -VMName "SQLDBA-Secondary" | Remove-VMDvdDrive
  - Renamed the Windows computer name (was still "WIN-V614QRHKTTS", identical
    to Primary - a real conflict). REAL PROBLEM #2: my first attempt used
    "SQLDBA-SECONDARY" (17 characters), which Windows silently truncated to
    "SQLDBA-SECONDAR" due to the 15-character NetBIOS computer name limit.
    Fixed by renaming to "SQLDBA-SECNDRY" (14 characters).
  - Rename-Computer -NewName "SQLDBA-SECNDRY" -Force
  - Restart-Computer -Force
  - Confirmed SERVERPROPERTY('ServerName') auto-updated to match after
    restart (default instance re-syncs with OS computer name automatically -
    no manual SQL Server rename needed).
*/

-- ============================================================================
-- STEP 2: Network connectivity between the two VMs
-- ============================================================================
/*
REAL PROBLEM #3: ping and port tests between the VMs' IPs
(192.168.1.213 Primary, 192.168.1.214 Secondary) both failed completely,
despite opening firewall rules for ICMP and port 1433 on both VMs. Root
cause (confirmed via web search): SQLLab-External-Switch is bound to a WiFi
adapter, and WiFi drivers commonly block VM-to-VM traffic due to MAC address
filtering - a well-documented Hyper-V limitation specific to WiFi-based
external switches. Fixed by enabling MAC address spoofing on both VMs'
network adapters.
*/

-- (PowerShell, on host)
-- New-NetFirewallRule -DisplayName "Allow ICMP-In" -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow
-- New-NetFirewallRule -DisplayName "Allow SQL Server 1433" -Direction Inbound -LocalPort 1433 -Protocol TCP -Action Allow
-- (run on both VMs)

-- Get-VMNetworkAdapter -VMName "SQLDBA-Primary" | Set-VMNetworkAdapter -MacAddressSpoofing On
-- Get-VMNetworkAdapter -VMName "SQLDBA-Secondary" | Set-VMNetworkAdapter -MacAddressSpoofing On

-- After this fix: ping succeeded (4/4 packets), Test-NetConnection on port
-- 1433 succeeded (TcpTestSucceeded: True).

-- ============================================================================
-- STEP 3: Enable Always On Availability Groups feature
-- ============================================================================
-- Done via SQL Server Configuration Manager on BOTH instances:
--   SQL Server Services -> SQL Server (MSSQLSERVER) -> Properties ->
--   Always On Availability Groups tab -> checked "Enable Always On
--   Availability Groups" -> Apply -> restarted the SQL Server service.

SELECT SERVERPROPERTY('IsHadrEnabled') AS hadr_enabled;
GO
-- Confirmed 1 on both instances after restart.

-- ============================================================================
-- STEP 4: Handle the cloned database before creating the AG
-- ============================================================================
-- SQLDBA-Secondary, being a full clone, had its own independent copy of
-- climate_dba. A real AG secondary needs to receive its copy through the
-- AG's own seeding process, not have a pre-existing separate copy.
USE master;
GO

ALTER DATABASE climate_dba SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE climate_dba;
GO
-- (run on SQLDBA-Secondary only)

-- ============================================================================
-- STEP 5: Fresh seed backup on Primary
-- ============================================================================
BACKUP DATABASE climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_ag_seed.bak'
WITH FORMAT, INIT, NAME = 'climate_dba-AG Seed Backup';

BACKUP LOG climate_dba
TO DISK = 'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\climate_dba_ag_seed.trn'
WITH FORMAT, INIT, NAME = 'climate_dba-AG Seed Log Backup';
GO

-- ============================================================================
-- STEP 6: Attempted the GUI wizard - hit a real, documented limitation
-- ============================================================================
/*
REAL PROBLEM #4: the New Availability Group Wizard's checkbox for selecting
climate_dba could not be checked, no matter what I tried (direct click,
keyboard focus + spacebar, restarting the wizard). Eventually the wizard
itself surfaced the real reason via a dialog: "This wizard cannot add a
database containing a database encryption key to an availability group.
Use the CREATE or ALTER AVAILABILITY GROUP Transact-SQL statement instead."

This is a genuine, documented SSMS wizard limitation - TDE-encrypted
databases (which climate_dba has been since Phase 6) cannot be added to an
AG through the GUI wizard at all. Switched to T-SQL entirely from this
point forward.
*/

-- ============================================================================
-- STEP 7: Create endpoints - first attempt with Windows Authentication
-- ============================================================================
/*
REAL PROBLEM #5: created endpoints using the default Windows Authentication
(ROLE = ALL with no explicit AUTHENTICATION clause). Both endpoints created
successfully, firewall port 5022 opened and confirmed reachable in both
directions (Test-NetConnection succeeded both ways) - but ALTER AVAILABILITY
GROUP ... JOIN failed with "Msg 47106: Download configuration timeout."

Root cause: these are standalone WORKGROUP machines (not domain-joined).
NT SERVICE\MSSQLSERVER is a local virtual account on each machine with no
way to authenticate to the other machine without a domain trust
relationship. This is a genuine, well-known limitation of workgroup-based
Always On setups - not a mistake, just requires a different authentication
approach.

FIX: dropped both endpoints and rebuilt using certificate-based
authentication instead of Windows Authentication.
*/

-- DROP ENDPOINT [Hadr_endpoint];  -- run on both instances first

-- ============================================================================
-- STEP 8: Certificate-based endpoint authentication (the working approach)
-- ============================================================================
-- On WIN-V614QRHKTTS (Primary):
CREATE CERTIFICATE [Primary_AG_Cert]
WITH SUBJECT = 'Primary AG Endpoint Certificate';

BACKUP CERTIFICATE [Primary_AG_Cert]
TO FILE = 'C:\ClimateData\Primary_AG_Cert.cer';
GO

-- On SQLDBA-SECNDRY:
CREATE CERTIFICATE [Secondary_AG_Cert]
WITH SUBJECT = 'Secondary AG Endpoint Certificate';

BACKUP CERTIFICATE [Secondary_AG_Cert]
TO FILE = 'C:\ClimateData\Secondary_AG_Cert.cer';
GO

-- Copied each .cer file to the OTHER machine (via host relay, since Guest
-- Services only works between host<->VM, not VM<->VM directly).

-- Recreated endpoints with certificate authentication instead of Windows Auth:
-- On WIN-V614QRHKTTS:
CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = 5022)
FOR DATA_MIRRORING (
    ROLE = ALL,
    AUTHENTICATION = CERTIFICATE [Primary_AG_Cert],
    ENCRYPTION = REQUIRED ALGORITHM AES
);
GO

-- On SQLDBA-SECNDRY:
CREATE ENDPOINT [Hadr_endpoint]
STATE = STARTED
AS TCP (LISTENER_PORT = 5022)
FOR DATA_MIRRORING (
    ROLE = ALL,
    AUTHENTICATION = CERTIFICATE [Secondary_AG_Cert],
    ENCRYPTION = REQUIRED ALGORITHM AES
);
GO

-- Established mutual trust: each side imports the other's certificate,
-- mapped to a login, granted CONNECT on the endpoint.
-- On WIN-V614QRHKTTS (trusting Secondary):
USE master;
GO

CREATE LOGIN [Secondary_AG_Login] WITH PASSWORD = '<STRONG_PASSWORD_HERE>';
CREATE USER [Secondary_AG_User] FOR LOGIN [Secondary_AG_Login];

CREATE CERTIFICATE [Secondary_AG_Cert]
AUTHORIZATION [Secondary_AG_User]
FROM FILE = 'C:\ClimateData\Secondary_AG_Cert.cer';

GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [Secondary_AG_Login];
GO

-- On SQLDBA-SECNDRY (trusting Primary) - mirror image:
CREATE LOGIN [Primary_AG_Login] WITH PASSWORD = '<STRONG_PASSWORD_HERE>';
CREATE USER [Primary_AG_User] FOR LOGIN [Primary_AG_Login];

CREATE CERTIFICATE [Primary_AG_Cert]
AUTHORIZATION [Primary_AG_User]
FROM FILE = 'C:\ClimateData\Primary_AG_Cert.cer';

GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [Primary_AG_Login];
GO

-- ============================================================================
-- STEP 9: Create the Availability Group
-- ============================================================================
-- NOTE: my first attempt used a guessed replica name 'SQLDBA-PRIMARY',
-- which failed (Msg 35237) because Primary's actual, never-renamed SQL
-- Server name is 'WIN-V614QRHKTTS' - the VM's Hyper-V display name and its
-- actual Windows/SQL Server identity are two different things.
SELECT SERVERPROPERTY('ServerName') AS server_name;  -- confirmed real name first

-- On WIN-V614QRHKTTS:
CREATE AVAILABILITY GROUP [ClimateDBA-AG]
WITH (CLUSTER_TYPE = NONE)
FOR DATABASE climate_dba
REPLICA ON
    'WIN-V614QRHKTTS' WITH (
        ENDPOINT_URL = 'TCP://192.168.1.213:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    ),
    'SQLDBA-SECNDRY' WITH (
        ENDPOINT_URL = 'TCP://192.168.1.214:5022',
        AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = AUTOMATIC
    );
GO

-- On SQLDBA-SECNDRY:
ALTER AVAILABILITY GROUP [ClimateDBA-AG] JOIN WITH (CLUSTER_TYPE = NONE);
ALTER AVAILABILITY GROUP [ClimateDBA-AG] GRANT CREATE ANY DATABASE;
GO

-- ============================================================================
-- STEP 10: Verify health and data synchronization
-- ============================================================================
SELECT
    ag.name AS ag_name, ar.replica_server_name, ars.role_desc,
    ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
JOIN sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
WHERE ag.name = 'ClimateDBA-AG';
GO
-- Confirmed both replicas CONNECTED and HEALTHY.

-- Enabled read access on the secondary to allow verification queries.
ALTER AVAILABILITY GROUP [ClimateDBA-AG]
MODIFY REPLICA ON 'SQLDBA-SECNDRY'
WITH (SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));
GO

-- Verified genuine, complete data replication on the secondary.
USE climate_dba;
GO
SELECT COUNT(*) AS total_rows FROM climate.daily_observations;  -- 113,522,932
SELECT COUNT(*) AS total_stations FROM climate.stations;         -- 132,501
GO

-- ============================================================================
-- STEP 11: Manual failover test - and a real split-brain incident
-- ============================================================================
/*
REAL PROBLEM #6: my first failover attempt used the standard
ALTER AVAILABILITY GROUP [ClimateDBA-AG] FAILOVER; statement, which failed
(Msg 47122) because CLUSTER_TYPE = NONE only supports FORCE_FAILOVER, not
a graceful coordinated failover - a direct, documented consequence of not
using a real WSFC cluster.
*/
-- ALTER AVAILABILITY GROUP [ClimateDBA-AG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
-- (run on SQLDBA-SECNDRY - succeeded, promoted to PRIMARY, verified with
-- matching row counts)

/*
REAL PROBLEM #7 - SPLIT BRAIN: after successfully failing over to
SQLDBA-SECNDRY, I attempted to fail back to WIN-V614QRHKTTS to complete a
round-trip test. This resulted in BOTH instances simultaneously believing
they were the primary replica - a genuine split-brain scenario. This is a
well-documented, real risk specific to CLUSTER_TYPE = NONE Availability
Groups: without a WSFC cluster's quorum-based arbitration, there is no
mechanism to prevent two replicas from both claiming primary role
simultaneously after a forced failover.

RECOVERY: dropped the Availability Group entirely on both instances,
verified clean state on both sides, and rebuilt it from scratch. Hit one
more issue along the way - a leftover standalone copy of climate_dba on
SQLDBA-SECNDRY (from an earlier drop that didn't clean up properly) had to
be manually dropped (with SET SINGLE_USER WITH ROLLBACK IMMEDIATE) before
automatic seeding would create a fresh, properly-joined copy.

LESSON DOCUMENTED: this is exactly why production Always On deployments
should use a real WSFC with Active Directory - it exists specifically to
prevent this scenario through quorum arbitration.
*/

-- Clean rebuild (same CREATE/JOIN statements as Step 9), then:
-- ALTER AVAILABILITY GROUP [ClimateDBA-AG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
-- (run once on SQLDBA-SECNDRY only - verified healthy, verified data intact,
-- deliberately did NOT attempt a round-trip failback this time, to avoid
-- repeating the split-brain scenario)

/*
================================================================================
End of Phase 9 script.

Summary: built a genuinely working Always On Availability Group across two
standalone VMs, through substantial real troubleshooting - a failed ISO
boot requiring a full VM clone instead, a WiFi virtual switch MAC filtering
issue, a workgroup authentication limitation requiring certificate-based
endpoints, and a real split-brain incident during failover testing that
required a full AG rebuild to resolve. Final state: healthy, synchronized
AG with a single, deliberate, verified manual failover completed.

See docs/phase-9-high-availability.md for the full narrative write-up and
screenshots.
================================================================================
*/
