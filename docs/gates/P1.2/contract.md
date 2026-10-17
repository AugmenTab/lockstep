# P1.2 Contract — PostgreSQL, migrations, readiness and recovery

- Contract ID: `C-P1.2@v1`
- Status: **FROZEN** at the test-freeze commit named in §8 (manual; no v2 Supervisor)
- Basis: `v2` at `3771f08` (P1.1 accepted, `docs/gates/P1.1/acceptance.md`)
- Authority: ADR-0002 / DG-02 **ACCEPTED** 2026-10-17 (Q1–Q8 as proposed)
- Traces: FR-APP-03, NFR-07, NFR-04 (DB secret handling), TESTING_STRATEGY §5

## 1. Objective

Give `lockstep` a real PostgreSQL 17 database with explicit, ordered,
forward-only migrations applied only by `lockstep db migrate`; a typed readiness
check that never pretends the database is healthy; one real DB-backed state
projection; and operator scripts for start, stop, status, backup and restore.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | PostgreSQL **17.11** image `postgres:17.11-bookworm@sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826`. Container `lockstep-postgres`, volume `lockstep-pgdata`, Docker network `lockstep-net`, published on `127.0.0.1:5433` only (5433 avoids a host PostgreSQL on 5432). |
| E2 | Database configuration is a JSON file named by **`LOCKSTEP_CONFIG`** (Launchpad's `CONFIG_PATH` pattern). Unset → readiness `DatabaseNotConfigured`, and the P1.1 behaviour is unchanged (liveness page says readiness is *not checked*). Set but unreadable, invalid, carrying unknown keys (e.g. a `rollbar` block), or readable by group/other → typed `ConfigError`, exit 66, no server. |
| E3 | `scripts/db up` generates a random password into `.local/config/pg-password` and `.local/config/lockstep.json` (both mode 0600). The password reaches PostgreSQL through `POSTGRES_PASSWORD_FILE`, never argv/env. The password type's `Show` is `<redacted>`; it never appears in logs, pages or CLI output. |
| E4 | Migrations live in `Lockstep.Persistence.Migrations` as `(MigrationId, description, SQL)` with strictly increasing ids. Ledger table `lockstep_schema_migrations(id, description, checksum, applied_at)`, created by an idempotent bootstrap. Checksum = SHA-256 of the SQL text. Each migration runs in its own transaction holding `pg_advisory_xact_lock`, re-reads the ledger inside the transaction, and inserts its ledger row with the DDL, so it is applied at most once. |
| E5 | Pure planning (`planMigrations`) refuses, with nothing applied: an invalid list (non-increasing ids), a checksum mismatch, an applied id unknown to the binary (DB ahead), or a gap (applied ids not a prefix of the list). |
| E6 | `lockstep db migrate`: if nothing is pending, no-op exit 0. If pending migrations exist **and** the ledger is non-empty, requires `--backup FILE` (existing, non-empty, modified after the last `applied_at`) or an explicit `--no-backup`; otherwise refuses (exit 75). An empty database needs no backup. `lockstep db status` prints revision and pending count. |
| E7 | Readiness (`Lockstep.Application.Database`): `Ready revision` only when connected and the ledger equals the binary's list; otherwise `NotReady` with `DatabaseNotConfigured`, `DatabaseUnreachable`, `AuthenticationFailed`, `DatabaseMissing`, `SchemaBehind n`, `SchemaInvalid refusal`, or `DatabaseError` (other). Connection failures are classified from the libpq message (no SQLSTATE exists before a session); timeout 3 s (`connect_timeout`). Exceptions never escape a readiness check. |
| E8 | `GET /api/readiness` → 200 `ready <revision>` or 503 `not_ready <reason>` (text/plain). `GET /api/health_check` stays liveness (204) in every state. The page shows the same readiness in words. |
| E9 | DB-backed projection: migration `0001` creates `lockstep_service_starts(id, started_at)`. `serve` records one row at startup **only when ready**; the page shows the count and latest start, read from PostgreSQL on each request. |
| E10 | Layering (ARCHITECTURE §2): Web → Application → Persistence → Foundation. Henforcer encodes "Web must not import Persistence" as a **mutual** tree dependency (each forbids the other). The request monad moves from `Lockstep.Foundation.Types` to `Lockstep.Web.Types` because it now carries an Application handle and Foundation is a leaf. |
| E11 | Integration DB: `scripts/check --integration` starts a disposable PostgreSQL 17.11 container on a private network per run (random superuser password) and removes it afterwards. Each test creates its own database. Missing connection settings **fail** the suite (never skip). |
| E13 | The P1.1-frozen runner files `test/unit/Main.hs` and `test/integration/Main.hs` hold no assertions. P1.2 changes them **additively only** (new imports and list entries). Check: `git diff f2154cf -- test/unit/Main.hs test/integration/Main.hs` contains no removed line. All other P1.1 test files stay byte-identical (§8 digests). |
| E12 | Backup/restore are `scripts/db backup` (`pg_dump -Fc` inside the PostgreSQL container → `.local/backups/<UTC>-r<revision>.dump` + `.sha256`) and `scripts/db restore FILE` (digest verified, then `pg_restore --clean --if-exists --single-transaction`). Verified by `scripts/lib/check-db-backup-restore` against the disposable container. |

## 3. Allowed paths

`src/Lockstep/{Foundation,Persistence,Application,Web}/**`, `app/lockstep/**`,
`test/unit/**` (new files only; P1.1 tests unchanged), `test/integration/**` (new
files; `Main.hs` may add groups), `scripts/**`, `Dockerfile` (add `libpq-dev`,
`postgresql-client` not needed), `package.yaml`, `lockstep.cabal`, `stack.yaml`,
`stack.yaml.lock`, `henforcer.toml`, `.gitignore`, `README.md`,
`THIRD_PARTY_LICENSES.md`, `docs/gates/P1.2/**`, `docs/architecture/ARCHITECTURE.md`
(mapping note for E10 only).

Out of scope: operator trust/CSRF (P1.3), commands/receipts (P1.4), dispatcher
(P1.5), command center (P1.6).

## 4. Production API the tests bind to

```haskell
-- Lockstep.Foundation.SystemConfig
data Secret            -- Show = "<redacted>"; revealSecret :: Secret -> Text
data DatabaseConfig = DatabaseConfig
  { dbHost :: Text, dbPort :: Port, dbName :: Text, dbUser :: Text, dbPassword :: Secret }
newtype SystemConfig = SystemConfig { databaseConfig :: DatabaseConfig }
data ConfigError = ConfigUnreadable String | ConfigInvalid String
  | ConfigUnknownKeys [Text] | ConfigInsecurePermissions FilePath
decodeSystemConfig :: LBS.ByteString -> Either ConfigError SystemConfig
loadSystemConfig :: FilePath -> IO (Either ConfigError SystemConfig)
mkSecret :: Text -> Secret

-- Lockstep.Foundation.Cli (additions)
Command: ... | DbMigrate BackupPolicy | DbStatus
data BackupPolicy = BackupRequiredIfApplied | BackupFile FilePath | NoBackup
CliError: ... | MissingSubcommand String | ConflictingOptions String String

-- Lockstep.Persistence.Migration
newtype MigrationId     -- Eq, Ord, Show; mkMigrationId :: Int -> Maybe MigrationId (>= 1); migrationIdInt
data Migration = Migration { migrationId :: MigrationId, migrationDescription :: Text, migrationSql :: Text }
newtype Checksum        -- Eq, Show; checksumText :: Checksum -> Text (lowercase hex SHA-256)
migrationChecksum :: Migration -> Checksum
data AppliedMigration = AppliedMigration { appliedId :: MigrationId, appliedChecksum :: Checksum }
data MigrationRefusal = InvalidMigrationList | ChecksumMismatch MigrationId
  | UnknownAppliedMigration MigrationId | MissingAppliedMigration MigrationId
planMigrations :: [Migration] -> [AppliedMigration] -> Either MigrationRefusal [Migration]

-- Lockstep.Persistence.Migrations
migrations :: [Migration]          -- production list

-- Lockstep.Application.Database
data NotReadyReason = DatabaseNotConfigured | DatabaseUnreachable | AuthenticationFailed
  | DatabaseMissing | SchemaBehind Int | SchemaInvalid MigrationRefusal | DatabaseError
data Readiness = Ready MigrationId | NotReady NotReadyReason
classifyConnectionFailure :: String -> NotReadyReason
readinessCode :: Readiness -> Text                 -- "ready 1", "not_ready schema_behind 1", ...
data DatabaseRuntime
openDatabase :: DatabaseConfig -> IO DatabaseRuntime
checkReadiness :: Maybe DatabaseRuntime -> IO Readiness
data ServiceStarts = ServiceStarts { startCount :: Int, latestStart :: UTCTime }
data MigrateError = MigrateRefused MigrationRefusal
  | MigrateFailed MigrationId [MigrationId]      -- failed id; ids applied before it
  | BackupRequired | BackupMissing FilePath | BackupStale FilePath
  | MigrateNotReady NotReadyReason
runMigrations :: [Migration] -> DatabaseRuntime -> IO (Either MigrateError [MigrationId])
migrateWithPolicy :: BackupPolicy -> [Migration] -> DatabaseRuntime -> IO (Either MigrateError [MigrationId])
readServiceStarts :: DatabaseRuntime -> IO (Maybe ServiceStarts)
recordServiceStart :: DatabaseRuntime -> IO ()
closeDatabase :: DatabaseRuntime -> IO ()

-- Lockstep.Web.Liveness
livenessPage :: Text -> Readiness -> Maybe ServiceStarts -> E.HTML
```

## 5. Tests (frozen before implementation; §8)

Unit (`lockstep-unit`, no network):

| Area | Cases |
|---|---|
| SystemConfig | valid file decodes; missing `database` / field → `ConfigInvalid`; top-level `rollbar` → `ConfigUnknownKeys ["rollbar"]`; unknown key inside `database` refused; port 0 / 70000 refused; `show` of a decoded config never contains the password |
| Cli | `db migrate` → `DbMigrate BackupRequiredIfApplied`; `--backup F`; `--backup=F`; `--no-backup`; `--backup` without value; `--backup F --no-backup` → `ConflictingOptions`; `db` alone → `MissingSubcommand "db"`; `db frob` → `UnknownCommand "db frob"`; `db status`; extra args refused; P1.1 `serve` behaviour unchanged |
| Migration plan | empty ledger → all pending in order; full ledger → none; prefix → remainder; checksum mismatch; unknown applied id; gap; invalid list (duplicate / decreasing ids); checksum of `SELECT 1;` equals its known SHA-256; production `migrations` list is valid and starts at 1 |
| Readiness | libpq message classification (refused, unknown host, timeout → unreachable; password failure → auth; missing database → missing; other → error); `readinessCode` for every constructor; no `NotReady` code starts with `ready` |
| Page | `livenessPage` for every `NotReady` reason says "not ready" and the reason, never "Ready"; `Ready` shows the revision and the service-start count; `DatabaseNotConfigured` says "not checked" |
| App | `application` (no database) → `/api/readiness` 503 `not_ready database_not_configured`; health stays 204 |

Integration (`lockstep-integration`, real PostgreSQL 17.11 + real processes):

| Case | Asserts |
|---|---|
| Fresh install | `lockstep db migrate` on an empty DB exits 0; ledger = production list; second run is a no-op |
| Ordered runner | a 3-migration test list applies in id order; ledger rows in order |
| Partial then rest | applying list[0..1] then the full list applies only the third |
| Failed migration | a migration with invalid SQL fails; its DDL and ledger row are absent; earlier revision intact |
| Checksum / ahead / gap | each refused before any SQL runs; ledger unchanged |
| Concurrency | two runners on separate connections apply each migration once |
| Readiness | `NotReady (SchemaBehind n)` before migrate, `Ready` after; wrong password → `AuthenticationFailed`; missing DB → `DatabaseMissing`; closed port → `DatabaseUnreachable` |
| Backup gate (library, `migrateWithPolicy` with a 2-migration list, because the production list has one migration) | applied ledger + pending: no flag → `BackupRequired`; missing file → `BackupMissing`; file older than the last `applied_at` → `BackupStale`; nothing applied in each refusal; fresh file or `NoBackup` → applies. The CLI maps these to exit 75 (not process-tested in P1.2). |
| Service HTTP | `serve` against an unmigrated DB: `/api/readiness` 503 `schema_behind`, health 204, page says not ready; after migrate + restart: 200 `ready`, page shows revision and start count |
| Restart | two `serve` runs → start count 2, persisted |
| Config errors | `serve` with an invalid config, a `rollbar` key, or a 0644 config exits 66 and listens nowhere |
| Secrets | the password never appears in `serve`/`db` stdout/stderr or in the page |

Script check `scripts/lib/check-db-backup-restore` (disposable container): backup
writes dump + digest; a deleted row returns after restore; a corrupted digest is
refused.

## 6. Verification

`scripts/check --integration` from a fresh clone; `scripts/db up && scripts/db
status`, `lockstep db migrate`, `scripts/db backup`, restart, readiness.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test; frozen tests never
edited. Stop on an Orville/libpq behaviour that makes a frozen expectation
impossible (ask), or on a new license exception. Rollback: revert P1.2 commits.

## 8. Freeze record

Frozen by the commit that introduces this section (`test(p1.2): …`, manual).

Baseline (`.local/evidence/P1.2-baseline-1.log`): against the P1.1 production
code the suites fail only with missing P1.2 modules/exports. Against throwaway
type-only stubs of §4 (scratch, not committed) both suites compiled under the
package's `-Weverything -Werror` flags and Henforcer; fourmolu and hlint clean.
Candidate defects corrected before freeze: `FilePath`, `filter`/`notElem` not
exported by Flipstone.Prelude; a redundant `Data.Int` import; one hlint hint.
P1.1 test files unchanged (their digests still verify); runner files changed
additively only (E13).

| File | SHA-256 |
|---|---|
| `test/unit/Main.hs` | `a8ae134dedfebbbbd66111376da5a23796f93993673dbbe5099079ebe2882a33` |
| `test/unit/Lockstep/Foundation/SystemConfigTest.hs` | `05479303227e665cea5b779b433e239be6836f60b3679a876bda8a94cf435651` |
| `test/unit/Lockstep/Foundation/CliDbTest.hs` | `415cb93c7c6cad5dc9619b02b26f93b1824bad9beef37b52f95623caf8b51545` |
| `test/unit/Lockstep/Persistence/MigrationTest.hs` | `a7c90ab304394839e021d94cd52b156c66292d88a16ed88abd92b8bc524ca919` |
| `test/unit/Lockstep/Application/ReadinessTest.hs` | `65ddc300aae7253685690b2d7295baa90ec1de9358812ac0324f341a665c7b79` |
| `test/unit/Lockstep/Web/LivenessPageTest.hs` | `5e66be56a892c0d11a00d9a3d3b6f3f6d31f8270d8badb2f2750c5fb52370ba4` |
| `test/unit/Lockstep/Web/ReadinessRouteTest.hs` | `fb9a02afa3337d99078538edec8a72a52b02cef4abd1f6b7113286d97bb92aed` |
| `test/integration/Main.hs` | `4f5c3171f537feb2c10d08dd6252f606c4d9d0fd4a155216d51084524109cba0` |
| `test/integration/Lockstep/Support/Postgres.hs` | `e9bef155543313aceeb816407fc73309752b6cb30c12277604b5a06d85e45197` |
| `test/integration/Lockstep/Support/Process.hs` | `4c866af8a89a18db3be2f1d2ee27d43417d5dd1592927f817a6bb3834ca02942` |
| `test/integration/Lockstep/MigrationDbTest.hs` | `e6a829b53c049e89f36eddff5f3353806b5954714b6cf44f3048df9bdac7fec5` |
| `test/integration/Lockstep/ServiceDbTest.hs` | `28d7762992ae177ea0fcd24eff6d72cec3f6404cacc2584a74249e05085a3edd` |
| `scripts/lib/check-db-backup-restore` | `e4e649665016ae3392c10f0f01403c99d20a2812b247ed3faf60affe2803b4cf` |
