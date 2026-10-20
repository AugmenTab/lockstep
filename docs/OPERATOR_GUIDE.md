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

Migration 0008 (C-P2.5) adds the durable ledger: Tickets, Work Orders, their events, effect
intents and observations, gate evidence, schedule decisions and Work Units. It only adds tables;
events, refusals, observations, evidence, schedule decisions and Profile sources can never be
updated or deleted. It changes nothing in the Phase 1 job tables. No command uses these tables
yet (operator commands arrive with C-P2.8); migrate with a backup as usual.

Migration 0009 (C-P2.6) adds one append-only table, `lockstep_effect_recoveries`: the record of
each recovery of an interrupted effect dispatch. It changes no existing table. As with 0008, no
command uses it yet; migrate with a backup as usual.

Migration 0010 (C-P2.7) adds one append-only table, `lockstep_effect_resolutions`. It records
how an uncertain effect outcome was resolved: by a destination lookup, by a human attestation
or retry, or as a late observation that conflicted with the durable state. It changes no
existing table. Migrate with a backup as usual.

Migration 0011 (C-P2.8) adds the sandbox destination: three tables
(`lockstep_sandbox_applications`, `lockstep_sandbox_keys`, `lockstep_sandbox_queryable`) that stand
for the external world of the model-free sandbox effects. They are not evidence. It changes no
existing table. Migrate with a backup as usual.

Migration 0012 (C-P2.9-R1) adds two columns to `lockstep_effect_intents`: the first dispatch
time and the activation that authorized the intent. It also allows two more kinds of resolution
record: a human abandonment and a human carry. Migrate with a backup as usual.

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
scripts/lockstep open [--port N]            # start if needed, open the sign-in page in your browser
```

`scripts/lockstep open` checks that the database is ready, starts the service if it is not
running (with a running service it uses that service's port), asks the installed CLI for a
one-time sign-in link and hands it to this machine's browser (`open` on macOS, `xdg-open` on
Linux, or the command in `LOCKSTEP_BROWSER`). Press **Sign in**. The link is never printed. While
the launcher runs it is visible in the process list to your OS user and root, and the browser
keeps it in its history, but it is single-use and expires within 5 minutes. Failures exit with a
reason: 69 not ready or not running, 75 a running service on another port, 70 no link or no
working browser launcher. Tip: `alias lockstep=<checkout>/scripts/lockstep`; every other
`lockstep …` command then runs the installed binary, like `scripts/service cli`.

By hand, without opening a browser:

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
`--idempotency-key` is given). Each time the form page loads, it gets a fresh key, so going Back
and submitting again counts as a new command. To repeat a command deliberately, reuse the key
with the CLI. Repeating a command with the same key and the same payload returns the same receipt;
reusing a key for a different command is refused; a command whose expected revision is stale is
recorded as `refused_stale`. Jobs run only in the service; closing the browser does not cancel
them. In the command center, a job shows `PASSED` only when it succeeded and its recorded outcome
still matches its row.

### Engineers and repositories (Phase 2, C-P2.1)

`lockstep engineer add NAME` and `lockstep repository register --engineer NAME
[--authoritative-remote REMOTE] PATH` give one Engineer exclusive ownership of one repository;
`lockstep repository list` shows them. A refusal prints `refused <code> decision <n>` (exit 65)
and is recorded with its reason in `lockstep_identity_decisions`. There is no release or
relocation command yet (DG-03 D-3.6). Registration reads the repository through Git in the
filesystem of the process that runs `lockstep`; the installed container mounts no host
repositories, so through `scripts/service cli` a host path is `path-not-found`. Known limits:
SSH host aliases from `~/.ssh/config` are not resolved, and only GitHub, GitLab and Bitbucket
remote paths compare case-insensitively (C-P2.1 §9).

### SDLC Profiles (Phase 2, C-P2.3)

`lockstep profile add FILE` (or `-` for standard input; through the installed service,
`scripts/lockstep profile add - < team.json`) registers the next version of a Profile and prints
its digest; adding the same version again with the same content prints `unchanged`. `profile list`
and `profile show ID [--version N]` print what is registered. `repository set-profile --engineer
NAME PROFILE` sets the repository's default Profile, and `profile resolve --engineer NAME --kind
KIND …` prints the effective Profile it would bind. Every `profile add` and `set-profile` attempt
is recorded in `lockstep_profile_decisions`; Profile rows and default assignments cannot be
updated or deleted (database triggers). A stored document that no longer reproduces its digest is
an integrity failure (exit 70) and is never used: restore the database from a backup.

### The ledger: tickets, work orders and sandbox effects (Phase 2, C-P2.8)

| Task | Command |
|---|---|
| Show everything, with each effect's status | `lockstep ledger show` (browser: `/operator/ledger`) |
| A ticket | `lockstep ticket create TITLE`, then `ticket accept TICKET --expected-revision N` |
| A work order and its gate evidence | `lockstep work-order create --ticket T --engineer NAME --priority N --path-class CLASS`, then `work-order evidence WO --artifact A --digest HEX --verifier V --approval none\|supervisor\|human` |
| Schedule and claim | `lockstep schedule run-once` |
| Start with sandbox effects | `lockstep supervisor start WO --expected-revision N --effect sandbox-repeatable[:MODE] …` |
| Execute or recover one effect | `lockstep supervisor execute-once [--lease-seconds N] [--timeout-ms N]` |
| Look one uncertain effect up | `lockstep supervisor reconcile-once` |
| Resolve an unknown outcome | `lockstep effects resolve OP --generation G --attest-applied E` (or `--attest-not-applied E`, or `--retry --acknowledge-duplication-risk`) |
| Halt, requeue, abandon | `lockstep work-order halt WO --expected-revision N --reason R`, `work-order requeue …`, `effects abandon OP --reason R` |
| The sandbox world | `lockstep sandbox show` |

The sandbox effects (`sandbox-repeatable`, `-idempotent`, `-queryable`, `-unqueryable`, one per
effect class) are model-free. Modes `apply` (default), `refuse`, `hang` and `apply-then-hang` let
you produce every outcome. A `hang` lasts until the timeout, or until you kill the process: a
killed `execute-once` is a real crash, and the next `execute-once` recovers by the effect's
class. An effect shows `PASSED` only when its destination answered that it applied; a human
attestation shows `ATTESTED`. The `supervisor` commands run Lockstep's own deterministic steps
once, on your request. There is no supervisor daemon.

After a halt and a requeue, the order's earlier effects do not run again by themselves (they
show `BLOCKED` or are refused `activation-superseded`). To let one run again under its original
operation id, carry it into the new activation yourself:
`lockstep effects carry OP --from-activation S --to-activation T`. S and T are the activations
you expect it to move between. If either has changed, the carry is refused `stale-carry`. A carry
is refused for an unknown outcome (resolve it first; a retry needs
`--acknowledge-duplication-risk`), for an effect still in flight, for an idempotent effect whose
key may have expired, and while the new activation has its own live effect with the same key
(`carry-conflict`; abandon one of them first). An effect you attested as not applied is carried
only with `--acknowledge-duplication-risk`, and the acknowledgment is recorded.
Abandoning an effect (`effects abandon`) also halts its work order, and both are recorded as
yours. An idempotent effect that was sent before is never sent again once its key may have
expired, whether by recovery or by a retry: it becomes `UNKNOWN` and its order halts. A human
retry of such an effect is refused with `idempotency-key-expired`: attest its outcome or abandon it. If
a restart created a new effect with the same key as an earlier one that is still live, the new
one is never sent. Its order halts with `effect-key-in-use`, and you abandon one of the two. A
queryable effect interrupted in flight waits for `supervisor reconcile-once`.

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
| `refused authoritative-remote-ambiguous` | Several remotes: name the repository's own with `--authoritative-remote`. |
| `refused weakens-gate` / `profile-conflict` from `profile resolve` | A specialization or override weakens or contradicts a gate; publish a stronger next version. |
| `exit 70` with "integrity failure" | A stored Profile was changed outside Lockstep; restore from backup. |

## 8. Verification and evidence

`scripts/check [--integration]` is the single verification command: format, lint and static
checks, build, unit tests, the no-live-model guard (provider-CLI sentinels, construction gate,
fault-plan refusal) and, with `--integration`, the real PostgreSQL/process suite. Gate records and
evidence live under `docs/gates/`; larger local evidence under `.local/evidence/`.
