# Lockstep v2

Private. Haskell rebuild of Lockstep on a Launchpad-derived foundation
(WAI/Warp, Orb, Beeline, Brigid). Branch `v2` is an orphan branch; the Python
v0.1 reference lives on `main` (tag `python-v0.1-final`).

Governance, architecture and gate evidence are in `docs/`. Start with
`docs/architecture/ARCHITECTURE.md`.

## Requirements

Docker only. GHC 9.10.3, Stack, fourmolu and hlint live in the dev container
(`Dockerfile`). No Node or Python runtime is needed.

## Verify

```sh
scripts/check                 # format, lint + static checks, build, unit tests
scripts/check --integration   # also real PostgreSQL + process/HTTP integration and backup/restore
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

## Licensing

Lockstep v2 has no chosen license yet and is not distributed. Launchpad-derived
portions are BSD-3-Clause (`LICENSE-LAUNCHPAD`). Third-party components are
listed in `THIRD_PARTY_LICENSES.md`.
