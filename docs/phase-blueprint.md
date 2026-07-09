# Project Blueprint — Phase & Sprint Breakdown

This document defines the scope, sprint-level steps, and "definition of done" for each phase. Update the `Status` column in the root `README.md` as each phase is completed — this file is the detail behind that table.

---

## Phase 0 — Repo & Folder Structure ✅

**Scope:** Local + remote repo setup, folder conventions, `.gitignore`.

**Sprints:**
1. Create local folder structure (`sql/`, `docs/`, `diagrams/`, `screenshots/`, `assets/`, `backups/`)
2. Initialize git, add `.gitignore`, first commit
3. Create GitHub repo, connect remote, push

**Definition of Done:** Repo pushed to GitHub with full folder skeleton and `.gitignore` in place.

---

## Phase 1 — New Database: Sourcing, Schema & Baseline

**Scope:** Source a new raw dataset (separate from `healthcare_dba`), design a schema, bulk-load it deliberately unoptimized, and capture baseline diagnostics — establishing the "before" state that later phases will improve against.

**Sprints:**
1. **Dataset selection** — identify and download a raw dataset large/complex enough to expose real performance problems
2. **Schema design** — design tables, relationships, and initial (naive) indexing strategy
3. **Bulk load** — load the raw data into the new database, intentionally skipping optimization (no useful indexes, poor data types, no partitioning, etc.)
4. **Baseline diagnostics** — capture initial query performance, execution plans, table/index sizes, and any obvious bottlenecks as a documented "before" snapshot

**Definition of Done:** New database exists on `SQLDBA-Primary`, fully loaded, with a documented baseline (real numbers, real query timings) that Phase 4 will later improve on.

---

## Phase 2 — Installation & Configuration

**Scope:** Verify and extend the existing SQL Server 2025 install from Project 1 against configuration best practices — not a reinstall.

**Sprints:**
1. Audit current server-level configuration (memory limits, MAXDOP, cost threshold for parallelism, TempDB file count/sizing)
2. Apply/document configuration standards appropriate for this workload
3. Verify SSMS setup and any additional tooling needed for this project

**Definition of Done:** Server configuration reviewed, documented, and adjusted where needed, with before/after settings recorded.

---

## Phase 3 — Storage & Database Maintenance

**Scope:** Filegroup design, capacity planning, and ongoing maintenance routines.

**Sprints:**
1. Review/redesign filegroup and file layout for the new database
2. Capacity planning — growth projections based on real data volume
3. Set up maintenance routines: statistics updates, index maintenance, integrity checks (`DBCC CHECKDB`)

**Definition of Done:** Filegroup strategy documented, maintenance routines scripted and scheduled (or ready for Phase 8 automation), integrity checks passing.

---

## Phase 4 — Performance Tuning

**Scope:** Diagnose and fix the real performance problems established in Phase 1's baseline.

**Sprints:**
1. Query optimization — identify worst-performing queries via execution plan analysis
2. Indexing strategy — add/adjust indexes based on actual usage patterns, not guesswork
3. Wait statistics & resource monitoring — identify true bottlenecks (CPU, memory, I/O, locking)
4. Memory & TempDB optimization
5. Blocking/deadlock analysis and resolution
6. **Before/after comparison** — re-run the Phase 1 baseline queries and document real improvement (or document honestly where tuning didn't help and why)

**Definition of Done:** Documented before/after performance numbers for at least the worst offenders from Phase 1, with honest notes on what was and wasn't fixable.

---

## Phase 5 — Backup & Recovery

**Scope:** Full backup/recovery strategy and a real restore drill.

**Sprints:**
1. Full, differential, and transaction log backup strategy design
2. Implement and test backup jobs
3. Point-in-time recovery drill — actually restore to a specific point and verify data
4. Disaster recovery plan documentation

**Definition of Done:** Backups running successfully, a real restore drill completed with verified results, DR plan documented.

---

## Phase 6 — Security

**Scope:** Authentication, authorization, and data protection.

**Sprints:**
1. Authentication model — SQL logins vs. Windows auth, roles and permissions design
2. Transparent Data Encryption (TDE) setup
3. Row-Level Security implementation (where applicable to the dataset)
4. Data masking for sensitive columns

**Definition of Done:** Least-privilege role model in place, TDE enabled and verified, RLS/masking demonstrated on relevant tables.

---

## Phase 7 — Auditing & Compliance

**Scope:** SQL Server Audit and change tracking.

**Sprints:**
1. Configure SQL Server Audit (server + database level)
2. Login auditing and security event monitoring
3. Change tracking implementation

**Definition of Done:** Audit specs active and verified capturing real events, change tracking demonstrated on a live table change.

---

## Phase 8 — SQL Server Agent & Automation

**Scope:** Scheduled jobs, maintenance plans, alerts.

**Sprints:**
1. Automate backups via SQL Server Agent jobs
2. Automate maintenance tasks from Phase 3 (index/stats/integrity checks)
3. Configure alerts and notifications for job failures / critical errors

**Definition of Done:** Jobs running on schedule with verified successful execution history, alerting tested (e.g., a deliberately failed job triggers a real notification).

---

## Phase 9 — High Availability (Always On Availability Groups)

**Scope:** Build out 2–3 replicas using `SQLDBA-Primary` as the AG primary.

**Sprints:**
1. Provision secondary replica VM(s)
2. Configure Always On Availability Groups, add the new database
3. Configure listener
4. Test automatic and manual failover
5. Validate synchronization health and monitor replica lag

**Definition of Done:** AG healthy across all replicas, a real failover (manual and/or automatic) performed and documented with actual observed downtime/sync behavior.

---

## Phase 10 — Monitoring

**Scope:** Ongoing observability using DMVs and Extended Events.

**Sprints:**
1. Build DMV-based queries for resource/session/query monitoring
2. Set up Extended Events sessions for key events (deadlocks, long-running queries, etc.)
3. Build a simple monitoring dashboard (or documented query set) for resource utilization

**Definition of Done:** Monitoring artifacts in place and demonstrated catching a real event (e.g., a deliberately induced slow query or deadlock shows up in the monitoring output).

---

## Phase 11 — Documentation & Portfolio Packaging

**Scope:** Final write-up and portfolio site integration.

**Sprints:**
1. Consolidate all phase docs into a coherent project narrative
2. Architecture diagrams (VM topology, AG topology, schema ERD)
3. Build portfolio site pages (`projects/sqlserver-enterprise-dba/index.html` + `phase-1.html` through `phase-N.html`), matching the existing dark-navy/cream design system with a project-specific accent color
4. Final review pass — verify all numbers/claims trace back to real documented results

**Definition of Done:** Portfolio site pages live and pushed, full project readable end-to-end as a coherent case study.
