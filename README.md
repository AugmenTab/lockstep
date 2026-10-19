# Lockstep v2

Private. Haskell rebuild of Lockstep on a Launchpad-derived foundation
(WAI/Warp, Orb, Beeline, Brigid). Branch `v2` is an orphan branch; the Python
v0.1 reference lives on `main` (tag `python-v0.1-final`).

Governance, architecture and gate evidence are in `docs/`. Start with
`docs/architecture/ARCHITECTURE.md`. To install and run the service, follow
`docs/OPERATOR_GUIDE.md`.

## Requirements

Docker only. GHC 9.10.3, Stack, fourmolu and hlint live in the dev container
(`Dockerfile`). No Node or Python runtime is needed.

## Verify

```sh
scripts/check                 # format, lint + static checks, build, unit tests, no-live-model guard
scripts/check --integration   # also real PostgreSQL + process/HTTP integration and backup/restore
scripts/service ...           # install / start / stop the service on this host (docs/OPERATOR_GUIDE.md)
scripts/a1                    # scenario A1, scripted, against the installed service
scripts/format                # format Haskell sources (host-side, via the dev image)
scripts/licenses              # dependency license inventory and policy check
```

The first run builds the dev image and fills the `lockstep-stack-root` Docker
volume with dependencies, which takes a while. Later runs reuse both.

## Database (ADR-0002)

PostgreSQL 17.11 runs in its own container, managed by `scripts/db`:

```sh
scripts/db up          # create/start lockstep-postgres (network lockstep-net, 127.0.0.1:5433)
scripts/db status
scripts/db backup      # .local/backups/<UTC>-r<revision>-<pid>.dump + .sha256
scripts/db restore F   # verifies F.sha256 first; stop lockstep serve before restoring
scripts/db down        # stops the container; data stays in volume lockstep-pgdata
```

The first `scripts/db up` writes `.local/config/lockstep.json` and
`.local/config/pg-password` (mode 0600, gitignored). Point `LOCKSTEP_CONFIG` at
the JSON file. Migrations are applied only explicitly:

```sh
lockstep db status
lockstep db migrate                 # empty database: applies everything
lockstep db migrate --backup FILE   # once migrations exist: needs a fresh backup
lockstep db migrate --no-backup     # or an explicit, recorded opt-out
```

`lockstep serve` never migrates. Without `LOCKSTEP_CONFIG` it runs with database
readiness "not checked"; with it, `GET /api/readiness` answers 200 `ready N` only
at the binary's schema revision, otherwise 503 `not_ready <reason>`.

## Run

```sh
lockstep serve              # 127.0.0.1:8000
lockstep serve --port 9000  # 127.0.0.1:9000
```

`lockstep serve` binds `127.0.0.1` only; there is no option to bind another
interface. The binary is built in the Linux dev container, so today it runs
there (`stack exec -- lockstep serve`). Operator install and browser access
from the host are documented in P1.7.

| Route | Meaning |
|---|---|
| `GET /` | Status page: liveness, database readiness, recorded service starts. |
| `GET /api/health_check` | 204 while the process is up (liveness only). |
| `GET /api/readiness` | 200 `ready N`, or 503 `not_ready <reason>`. |
| `GET /operator` | Operator session page (needs a session). |

## Operator sign-in (C-P1.3)

```sh
lockstep operator sign-in [--port N]  # prints a one-time link, valid 5 minutes
lockstep operator sign-out-all        # revokes every browser session
```

Whoever can run `lockstep` with the `LOCKSTEP_CONFIG` file is the operator. Open
the printed link in a browser on the same machine and confirm: the browser gets
a 12-hour session cookie. Both commands need a ready database (exit 69 if not).
Every request must be addressed to `127.0.0.1:<port>` exactly (not
`localhost`), and every form submission must come from a page of the service.

## Opening the command center (C-OPEN)

```sh
scripts/lockstep open [--port N]
```

Host-side: starts the installed service if needed and opens its one-time sign-in page in this
machine's browser, without printing the link. `scripts/lockstep ARGS…` runs any other command
with the installed binary. See `docs/OPERATOR_GUIDE.md` §5.

## Operator commands (C-P1.4)

```sh
lockstep workspace show
lockstep workspace rename --expected-revision N [--idempotency-key K] NAME
```

A command applies only if the workspace is still at revision `N`; otherwise it
is recorded as `refused_stale`. Every accepted command gets a durable receipt;
repeating a command with the same key returns the same receipt instead of
applying it twice, and reusing a key for a different command is refused. The
operator page (`/operator`) submits the same command through the browser.

## Background jobs (C-P1.5)

```sh
lockstep job queue --expected-revision N [--steps S] [--step-ms M] [--fail-at-step K] [--idempotency-key K]
lockstep job show JOB
```

Queueing only records the job (and its receipt); the running `lockstep serve`
executes it in the background, one short transaction per step. Closing the
browser or dropping the request does not cancel it. On a normal stop the
service returns a running job to the queue; after a crash the job is reclaimed
once its lease expires and resumes from its last completed step. Jobs are
model-free no-ops; the browser form is at `/operator/jobs/new`.

## Command center (C-P1.6)

`/operator/center` (signed in) shows job and receipt counts by status, the
newest commands, and an evidence table for jobs (criterion, method, expected,
actual, disposition, evidence). Everything is read from the database when the
page is rendered. A job shows `PASSED` only when it succeeded and its stored
outcome digest still matches its row; queued, running, failed, edited or
unrecorded jobs never show as passed. The machine summary is not acceptance.

## Engineers and repository ownership (C-P2.1)

```sh
lockstep engineer add NAME
lockstep repository register --engineer NAME [--authoritative-remote REMOTE] PATH
lockstep repository list
```

Each Engineer owns exactly one repository, and each repository has exactly one
owning Engineer (DG-03). `PATH` must be the top level of a repository's main
worktree (not a linked worktree, subdirectory, bare repository, shallow clone
or submodule). A repository is identified by the physical Git common directory
and by its authoritative remote: the only remote, or the one named with
`--authoritative-remote` when there are several. A second registration of the
same directory (through any path, symlink or case spelling) or of another clone
with the same authoritative remote is refused. Shared history alone is not
identity, so forks and template-derived projects can be registered. Every
attempt, accepted or refused, is recorded with its reason. Git is only read,
never changed. Registration observes the filesystem of the process that runs
`lockstep`; the installed service container (`scripts/service cli`) mounts no
host repositories.

## SDLC Profiles (C-P2.3)

```sh
lockstep profile add FILE            # or - to read the JSON document from standard input
lockstep profile list
lockstep profile show ID [--version N]
lockstep repository set-profile --engineer NAME PROFILE
lockstep profile resolve --engineer NAME --kind KIND [--class TAG]... [--path-class CLASS]... [--non-behavioural RATIONALE]
```

A Profile is a versioned, declarative JSON document of gates over a fixed vocabulary
(DG-05; `docs/gates/P2.3/contract.md` §4). Versions are immutable and numbered 1, 2, 3, …; each
is identified by the SHA-256 of its canonical rendering. The effective Profile for a piece of
work is resolved from the built-in baseline, the repository default, the specializations the
default declares for the work's kind or class, and human-approved stricter overrides. A later
layer may only add or strengthen gates; any weakening, any conflict between sources at one level,
and any attempt to waive one of the nine universal invariants is refused. `profile resolve` is a
dry run that prints the effective Profile and its digest; binding it to a Work Order comes with
durable Work Orders (C-P2.5). Through the installed service: `scripts/lockstep profile add - < file.json`.

## Licensing

Lockstep v2 has no chosen license yet and is not distributed. Launchpad-derived
portions are BSD-3-Clause (`LICENSE-LAUNCHPAD`). Third-party components are
listed in `THIRD_PARTY_LICENSES.md`.
