# Project Blueprint — Phase & Sprint Breakdown

This is my planning doc for how I'll approach each phase — scope, sprint steps, and what "done" looks like. I'll update the `Status` column in the root `README.md` as I complete each phase, but this file is the detail behind that table.

---

## Phase 0 — Repo & Folder Structure ✅

**What I did:** Set up the local + remote repo and folder conventions.

**Sprints:**
1. Created the local folder structure (`sql/`, `docs/`, `diagrams/`, `screenshots/`, `assets/`, `backups/`)
2. Initialized git, added `.gitignore`, made the first commit
3. Created the GitHub repo, connected the remote, pushed

**Done when:** Repo pushed to GitHub with the full folder skeleton and `.gitignore` in place. ✅

---

## Phase 1 — New Database: Sourcing, Schema & Baseline

**What I'm planning:** I need to source a new raw dataset (separate from `healthcare_dba`), design a schema for it, bulk-load it deliberately unoptimized, and capture baseline diagnostics — this is my "before" state that I'll improve against later.

**Sprints:**
1. **Dataset selection** — I'll find and download a raw dataset large/complex enough to actually expose real performance problems
2. **Schema design** — I'll design the tables, relationships, and a naive (non-optimized) indexing strategy
3. **Bulk load** — I'll load the raw data in, intentionally skipping optimization (no useful indexes, poor data types, no partitioning)
4. **Baseline diagnostics** — I'll capture initial query performance, execution plans, table/index sizes, and any obvious bottlenecks as a documented "before" snapshot

**Done when:** I have a new database on `SQLDBA-Primary`, fully loaded, with a documented baseline (real numbers, real query timings) that I'll come back to in Phase 4.

---

## Phase 2 — Installation & Configuration

**What I'm planning:** I'll verify and extend the existing SQL Server 2025 install from Project 1 against configuration best practices — not a reinstall.

**Sprints:**
1. Audit the current server-level configuration (memory limits, MAXDOP, cost threshold for parallelism, TempDB file count/sizing)
2. Apply and document any configuration changes appropriate for this workload
3. Verify SSMS setup and any additional tooling I need for this project

**Done when:** I've reviewed and documented the server configuration, adjusted where needed, and recorded before/after settings.

---

## Phase 3 — Storage & Database Maintenance

**What I'm planning:** Filegroup design, capacity planning, and ongoing maintenance routines for the new database.

**Sprints:**
1. Review/redesign filegroup and file layout
2. Do capacity planning based on real data volume and growth projections
3. Set up maintenance routines: statistics updates, index maintenance, integrity checks (`DBCC CHECKDB`)

**Done when:** I've documented the filegroup strategy, scripted the maintenance routines (ready for Phase 8 automation), and integrity checks are passing.

---

## Phase 4 — Performance Tuning

**What I'm planning:** This is where I diagnose and fix the real performance problems I established in Phase 1's baseline.

**Sprints:**
1. Query optimization — identify the worst-performing queries via execution plan analysis
2. Indexing strategy — add/adjust indexes based on actual usage patterns, not guesswork
3. Wait statistics & resource monitoring — find the true bottlenecks (CPU, memory, I/O, locking)
4. Memory & TempDB optimization
5. Blocking/deadlock analysis and resolution
6. **Before/after comparison** — I'll re-run the Phase 1 baseline queries and document the real improvement (or document honestly if tuning didn't help and why)

**Done when:** I have documented before/after performance numbers for at least the worst offenders from Phase 1, with honest notes on what was and wasn't fixable.

---

## Phase 5 — Backup & Recovery

**What I'm planning:** A full backup/recovery strategy, tested with a real restore drill.

**Sprints:**
1. Design the full, differential, and transaction log backup strategy
2. Implement and test the backup jobs
3. Run a point-in-time recovery drill — actually restore to a specific point and verify the data
4. Document the disaster recovery plan

**Done when:** Backups are running successfully, I've completed a real restore drill with verified results, and the DR plan is documented.

---

## Phase 6 — Security

**What I'm planning:** Authentication, authorization, and data protection for the database.

**Sprints:**
1. Design the authentication model — SQL logins vs. Windows auth, roles and permissions
2. Set up Transparent Data Encryption (TDE)
3. Implement Row-Level Security (where it applies to my dataset)
4. Apply data masking to sensitive columns

**Done when:** I have a least-privilege role model in place, TDE enabled and verified, and RLS/masking demonstrated on relevant tables.

---

## Phase 7 — Auditing & Compliance

**What I'm planning:** SQL Server Audit and change tracking.

**Sprints:**
1. Configure SQL Server Audit (server + database level)
2. Set up login auditing and security event monitoring
3. Implement change tracking

**Done when:** My audit specs are active and verified capturing real events, and I've demonstrated change tracking on a live table change.

---

## Phase 8 — SQL Server Agent & Automation

**What I'm planning:** Scheduled jobs, maintenance plans, and alerts.

**Sprints:**
1. Automate backups via SQL Server Agent jobs
2. Automate the Phase 3 maintenance tasks (index/stats/integrity checks)
3. Configure alerts and notifications for job failures or critical errors

**Done when:** My jobs are running on schedule with verified successful execution history, and I've tested alerting (e.g., deliberately failed a job and confirmed I got a real notification).

---

## Phase 9 — High Availability (Always On Availability Groups)

**What I'm planning:** Build out 2–3 replicas using `SQLDBA-Primary` as the AG primary.

**Sprints:**
1. Provision the secondary replica VM(s)
2. Configure Always On Availability Groups and add the new database
3. Configure the listener
4. Test automatic and manual failover
5. Validate synchronization health and monitor replica lag

**Done when:** My AG is healthy across all replicas, and I've performed and documented a real failover (manual and/or automatic) with actual observed downtime/sync behavior.

---

## Phase 10 — Monitoring

**What I'm planning:** Ongoing observability using DMVs and Extended Events.

**Sprints:**
1. Build DMV-based queries for resource/session/query monitoring
2. Set up Extended Events sessions for key events (deadlocks, long-running queries, etc.)
3. Build a simple monitoring dashboard (or documented query set) for resource utilization

**Done when:** My monitoring artifacts are in place and I've demonstrated them catching a real event (e.g., a deliberately induced slow query or deadlock shows up in the output).

---

## Phase 11 — Documentation & Portfolio Packaging

**What I'm planning:** Final write-up and portfolio site integration.

**Sprints:**
1. Consolidate all my phase docs into a coherent project narrative
2. Create architecture diagrams (VM topology, AG topology, schema ERD)
3. Build the portfolio site pages (`projects/sqlserver-enterprise-dba/index.html` + `phase-1.html` through `phase-N.html`), matching my existing dark-navy/cream design system with a project-specific accent color
4. Do a final review pass — verify all numbers/claims trace back to real documented results

**Done when:** My portfolio site pages are live and pushed, and the full project reads end-to-end as a coherent case study.
