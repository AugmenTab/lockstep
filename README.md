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
scripts/check --integration   # also the real-process/HTTP integration suite
```

The first run builds the dev image and fills the `lockstep-stack-root` Docker
volume with dependencies, which takes a while. Later runs reuse both.

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
| `GET /` | Liveness page. It does **not** check the database (readiness arrives in P1.2). |
| `GET /api/health_check` | 204 while the process is up (liveness only). |

## Licensing

Lockstep v2 has no chosen license yet and is not distributed. Launchpad-derived
portions are BSD-3-Clause (`LICENSE-LAUNCHPAD`). Third-party components are
listed in `THIRD_PARTY_LICENSES.md`.
