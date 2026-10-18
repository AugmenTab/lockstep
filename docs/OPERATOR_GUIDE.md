# Lockstep v2 — Operator guide

For the single local operator of this machine. Every procedure here was exercised on macOS
(arm64) with OrbStack (Docker Engine 29.4.0) during P1.7 (`docs/gates/A/evidence/a1/`). Lockstep is private
and not distributed.

## 1. What runs where

| Part | Where | Notes |
|---|---|---|
| Build and tests | Docker image `lockstep-dev:p1` (GHC 9.10.3, Stack) | The host needs only Docker and Git. |
| PostgreSQL 17 | Container `lockstep-postgres`, volume `lockstep-pgdata`, `127.0.0.1:5433` | Managed by `scripts/db` (ADR-0002). |
| The service | Container `lockstep-service` running the installed binary | Binds `127.0.0.1` only; host networking forwards it to this machine's `127.0.0.1:8000` only (measured on OrbStack; re-run `scripts/a1` if you change the Docker runtime). |
| Secrets | `.local/config/lockstep.json` (mode 0600, gitignored) | Database password. Never printed. Whoever can read it is the operator. |
| Backups | `.local/backups/` | `pg_dump` custom format with a `.sha256` file. |

The service needs no Node or Python runtime; its stylesheet is embedded in the binary.

## 2. Fresh install

```sh
git clone <repository> lockstep && cd lockstep && git checkout v2
scripts/check --integration        # builds the dev image; all six steps must say PASSED
scripts/db up                      # creates PostgreSQL and .local/config/lockstep.json
scripts/service install            # builds the release binary into .local/install
scripts/service cli db migrate     # an empty database needs no backup
scripts/service start              # http://127.0.0.1:8000/
```

`scripts/service install` records the commit, a dirty flag and the binary's SHA-256 in
`.local/install/VERSION`. Install from a clean checkout of the commit you mean to run.

## 3. Database operations (ADR-0002)

| Task | Command |
|---|---|
| Start / stop PostgreSQL | `scripts/db up` / `scripts/db down` (data stays in the volume) |
| State and schema revision | `scripts/db status`, `scripts/service cli db status` |
| Back up | `scripts/db backup` (prints the file path) |
| Migrate | `scripts/service cli db migrate --backup .local/backups/<file>.dump` |
| Migrate without a backup (recorded opt-out) | `scripts/service cli db migrate --no-backup` |
| Restore | `scripts/service stop`, then `scripts/db restore .local/backups/<file>.dump` |

Once any migration is applied, `db migrate` refuses (exit 75) without a backup newer than the
last applied migration, or an explicit `--no-backup`. Migrations are forward-only; recovery from
a bad migration is a restore of the pre-migration backup. `lockstep serve` never migrates: with a
schema behind the binary, `/api/readiness` answers 503 and the status page says so.

## 4. The service

| Task | Command |
|---|---|
| Start (default port 8000) | `scripts/service start [--port N]` |
| Stop (SIGTERM; running jobs return to the queue) | `scripts/service stop` |
| Clean restart | `scripts/service restart` |
| State | `scripts/service status` |
| Log | `scripts/service logs` (the last run's log is kept in `.local/install/last-run.log`) |
| Any CLI command against the same database | `scripts/service cli <command…>` |

Health: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/health_check` → `204`.
Readiness: `curl -s http://127.0.0.1:8000/api/readiness` → `ready 5`.

**Start the service after migrating.** The background dispatcher starts only if the database is
ready when the service starts; after a migration, restart the service.

## 5. Signing in

```sh
scripts/service cli operator sign-in        # prints a one-time link, valid 5 minutes
```

Open the link in a browser on this machine and press **Sign in**. The browser gets a 12-hour
session. Use `http://127.0.0.1:8000`, not `localhost` (refused by design). Sign out from
`/operator`; `scripts/service cli operator sign-out-all` revokes every session.

## 6. Commands, jobs and evidence

| Task | Browser | CLI |
|---|---|---|
| Rename the workspace | `/operator` form | `scripts/service cli workspace rename --expected-revision N NAME` |
| Queue a model-free no-op job | `/operator/jobs/new` | `scripts/service cli job queue --expected-revision N [--steps S] [--step-ms M] [--fail-at-step K]` |
| A receipt | `/operator/receipts/<id>` | printed by the command |
| A job | its receipt page | `scripts/service cli job show <id>` |
| Status, activity, evidence | `/operator/center` | — |

Every command has an idempotency key (the browser form makes one; the CLI generates one unless
`--idempotency-key` is given). Repeating a command with the same key returns the same receipt;
reusing a key for a different command is refused; a command whose expected revision is stale is
recorded as `refused_stale`. Jobs run only in the service; closing the browser does not cancel
them. In the command center, a job shows `PASSED` only when it succeeded and its recorded outcome
still matches its row.

## 7. Troubleshooting

| Symptom | Cause / action |
|---|---|
| `403` in the browser | Not `127.0.0.1:<port>`, or a form from another origin. Use the exact address. |
| `401` on `/operator` | No session: run `scripts/service cli operator sign-in`. |
| Sign-in link refused | Used, expired (5 min) or malformed: issue a new one. |
| Jobs stay `queued` | The service was started before the database was ready: `scripts/service restart`. |
| `exit 69` from a CLI command | The database is not ready: `scripts/service cli db status`. |
| `exit 75` from `db migrate` | Take `scripts/db backup` and pass `--backup FILE`. |
| `exit 78` | `LOCKSTEP_FAULT_PLAN` is set; this build refuses fault plans. Unset it. |

## 8. Verification and evidence

`scripts/check [--integration]` is the single verification command: format, lint and static
checks, build, unit tests, the no-live-model guard (provider-CLI sentinels, construction gate,
fault-plan refusal) and, with `--integration`, the real PostgreSQL/process suite. Gate records and
evidence live under `docs/gates/`; larger local evidence under `.local/evidence/`.
