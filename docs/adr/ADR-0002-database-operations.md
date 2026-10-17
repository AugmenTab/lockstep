# ADR-0002 — PostgreSQL provisioning, migrations, backup and recovery (DG-02)

- Status: **PROPOSED** — awaiting the human owner's decision. Blocks the P1.2 Contract freeze.
- Gate: DG-02 (DB boot / backup / migration / deployment packaging)
- Affects: FR-APP-03, NFR-07, NFR-08, TESTING_STRATEGY §5
- Evidence: Launchpad `11886bf` (`src/Launchpad/REPL.hs`, `Database/Schema.hs`,
  `compose.yml`); Orville `2f493550` (`orville-postgresql/src/Orville/PostgreSQL/AutoMigration.hs`,
  `orville-postgresql/compose.yaml`); SOURCE_REGISTER SRC-OBS-03

## What exists today (facts)

| Item | Launchpad / Orville at the pins |
|---|---|
| Schema change | `startLaunchpad` calls `autoMigrateSchema defaultOptions launchpadSchema` on **every start**. It diffs the declared tables against `pg_catalog` and applies whatever closes the gap. There is no migration history table, no ordering, no checksum and no down/forward-recovery path. |
| Orville support | `AutoMigration` only (plus `generateMigrationPlan`/`executeMigrationPlan` and an advisory `withMigrationLock`). No ordered-migration runner. |
| PostgreSQL version | Launchpad dev compose: `postgres:15.8-alpine`. Orville's test matrix: 14.13, 15.8, 16.4, **17.0**, **18.0**. |
| Provisioning | Docker Compose service with fixed user/password `launchpad/launchpad`, published on host port 7000 (all interfaces). |
| Backup / restore | None. |
| Readiness | `/api/health_check` returns 204 unconditionally. |

## Decision requested (one consolidated answer)

| # | Question | Recommended | Alternatives and risks |
|---|---|---|---|
| Q1 | How is PostgreSQL provisioned and started on the single host? | **Docker container managed by `scripts/db`** (`up`/`down`/`status`), pinned image, named volume `lockstep-pgdata`, published on **127.0.0.1 only**. Lockstep itself only takes a connection config; it never starts or stops the server. | (b) Host-installed PostgreSQL (Homebrew/apt) with the same connection config: supported by the same config but not scripted. (c) Lockstep spawns its own `postgres` child: more moving parts and a second lifecycle to supervise; not recommended. |
| Q2 | Which major version? | **PostgreSQL 17** (image pinned by digest, e.g. `postgres:17.x-bookworm`). Supported to Nov 2029, in Orville's test matrix, already present locally. | 18: newest, also in Orville's matrix, fewer patch releases yet. 15 (Launchpad's): EOL Nov 2027. |
| Q3 | Who owns migrations, and how are they ordered? | **Explicit, ordered, forward-only migrations in Haskell source** (`Lockstep.Persistence.Migrations`): a list of `(id, description, SQL)`; applied by **`lockstep db migrate`**, each in its own transaction, recorded in `lockstep_schema_migrations` (id, checksum, applied_at). Applied migrations are immutable: a checksum mismatch is a typed startup refusal. Orville is used for queries/marshalling, **not** for auto-migration. | (b) Keep Orville auto-migration at startup: fastest, but violates FR-APP-03 ordering and leaves no history. (c) External tool (dbmate/sqitch/flyway): adds a non-Haskell runtime dependency (NFR-07). |
| Q4 | What does `lockstep serve` do when the schema is not current? | **Refuse readiness, never migrate implicitly.** `serve` starts, `/api/health_check` stays liveness (204), new `/api/readiness` returns 503 with a typed reason (`DatabaseUnreachable`, `AuthenticationFailed`, `SchemaBehind n`, `SchemaAhead/Unknown`, `ChecksumMismatch`), and the page shows the same reason. 200 only when connected at the expected revision. | Exit at startup instead: also truthful, but no visible page explaining why. |
| Q5 | Initial installation? | `scripts/db up` creates the container, role and database; a random password is generated into a local config file `.local/config/lockstep.json` (mode 0600, gitignored, never printed). `lockstep db migrate` brings an empty database to head. | Fixed dev password in compose (Launchpad): simpler, but a committed secret. |
| Q6 | Backup and restore? | `scripts/db backup` → `pg_dump --format=custom` into `.local/backups/<UTC timestamp>-<revision>.dump` with SHA-256; `scripts/db restore <file>` → `pg_restore --clean --if-exists` while the service is stopped. **`lockstep db migrate` refuses to run without a backup newer than the last applied migration** unless given `--no-backup` explicitly (recorded). | Continuous WAL archiving / PITR: more durable, much more operation; not needed for a single local operator now. |
| Q7 | Recovery policy? | **Forward-only.** A failed migration rolls back its own transaction and leaves the previous revision intact. Recovery from a bad *applied* migration is a new forward migration, or restore of the pre-migration backup. No down-migrations. | Down-migrations: more code paths that are rarely tested. |
| Q8 | Test databases? | `scripts/check --integration` starts a disposable PostgreSQL 17 container on a private Docker network; each test module gets a fresh database cloned from a migrated template (TESTING_STRATEGY §5). | Shared long-lived test DB: faster, leaks state between runs. |

## Consequences if accepted

- P1.2 implements Q1–Q8 with real-PostgreSQL tests: fresh install, ordered migrate,
  restart, checksum refusal, unreachable/misconfigured DB shown truthfully, and a
  backup → restore round trip.
- Launchpad's `autoMigrateSchema` call, `Database/Schema.hs` registration list and
  the fixed compose credentials are not imported.
- `scripts/db` and `.local/backups/` become documented operator surfaces (P1.7).

## Approval

| Field | Value |
|---|---|
| Decision | _pending_ |
| Approver | _human owner_ |
| Date | _pending_ |
| Amendments | _none yet_ |
