# Enterprise SQL Server DBA Project

A hands-on portfolio project simulating the real-world responsibilities of an enterprise SQL Server DBA — starting from a deliberately unoptimized database and progressing through performance tuning, high availability, backup & recovery, security, auditing, automation, and monitoring on SQL Server 2025.

This is the follow-up to my [PostgreSQL → SQL Server migration project](https://github.com/aryobeen007/sqlserver-postgresql-migration), reusing the same `SQLDBA-Primary` VM as the foundation for the Always On Availability Group work in Phase 9.

---

## Environment

- **Host:** Windows 11 Pro, 64 GB RAM
- **VM:** Hyper-V, `SQLDBA-Primary` — Windows Server 2025 Standard, Gen 2, 16 GB dynamic memory, 8 vCPUs, 80 GB VHDX
- **SQL Server:** 2025 Enterprise Developer Edition, Mixed Mode authentication, default instance
- **New database for this project:** a separate, deliberately unoptimized database — built alongside the existing `healthcare_dba` database from Project 1, not replacing it

---

## Phases

| Phase | Topic | Status |
|---|---|---|
| 0 | Repo & Folder Structure | ✅ Complete |
| 1 | New Database: Sourcing, Schema & Baseline | ✅ Complete |
| 2 | Installation & Configuration | ✅ Complete |
| 3 | Storage & Database Maintenance | ✅ Complete |
| 4 | Performance Tuning | ✅ Complete |
| 5 | Backup & Recovery | ✅ Complete |
| 6 | Security | ✅ Complete |
| 7 | Auditing & Compliance | ✅ Complete |
| 8 | SQL Server Agent & Automation | ✅ Complete |
| 9 | High Availability (Always On AG) | ✅ Complete |
| 10 | Monitoring | ✅ Complete |
| 11 | Documentation & Portfolio Packaging | ✅ Complete |

See [`docs/phase-blueprint.md`](docs/phase-blueprint.md) for the detailed scope, sprint breakdown, and definition-of-done for each phase.

---

## Repository Structure

```
sqlserver-enterprise-dba/
├── sql/                  # T-SQL scripts, organized per phase
├── docs/                 # Phase write-ups + this blueprint
├── diagrams/             # Architecture / ERD diagrams
├── screenshots/           # Milestone screenshots (numbered sequentially)
├── assets/               # Portfolio branding assets (logos, hero images)
└── backups/              # Local backup files (not tracked in git)
```

---

## Status Legend

- ⬜ Not Started
- 🔄 In Progress
- ✅ Complete
