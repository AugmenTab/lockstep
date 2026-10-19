# Contract — `lockstep open` (Phase 2 convenience increment)

- Contract ID: `C-OPEN@v1`
- Status: **FROZEN** (2026-10-18)
- Authority: `.local/plans/phase-02.md` §4 (bounded, independent of the Gate B critical path). Gate A
  finding 2 (sign-in usability). Session-cookie option (a) and the P1.3 trust design are unchanged.
- Writer: the single writing agent (manual).

## 1. The host/container boundary, measured

The installed `lockstep` binary runs only inside the service container (`scripts/service`, Linux
image; the host has no GHC and no native binary). A browser launched inside that container is not
the operator's browser. `lockstep open` is therefore a **host-side** command. It reuses
`scripts/service` (start, the installed CLI) and the existing CLI-issued one-time sign-in token
(P1.3 E2), and hands the link to the host's own launcher (`open` on macOS, `xdg-open` on Linux).

## 2. Decisions

| # | Decision |
|---|---|
| O1 | **Entry point.** `scripts/lockstep` is the user-facing host command. `scripts/lockstep open [--port N]` opens the browser; any other arguments go unchanged to the installed binary (`scripts/service cli …`), so `alias lockstep=<checkout>/scripts/lockstep` gives one `lockstep` command. `open` is implemented as `scripts/service open`. No daemon, no new authentication, no long-lived token. |
| O2 | **Order** (each failure typed, with a fixed message and no token): usage (`64`); not installed (`69`); configuration missing (`66`); the database not ready, checked with the installed CLI **before** anything is started (`69`, with the readiness reason); a service container that exists but is not running (`69`); a running service on another port than `--port` (`75`); start through `scripts/service start` when nothing is running, or a start that does not answer (`69`); the sign-in link not issued or malformed (`70`); no browser launcher (`70`); the launcher fails (`70`). On success the command prints one line naming the service address. |
| O3 | **Port.** With a running service, its own `--port` (read from the container) is used; `--port N` must agree. With none, `--port N` or the `scripts/service` default 8000. |
| O4 | **Launcher.** `LOCKSTEP_BROWSER` (one command, given the link as its only argument) if set; otherwise `open` on macOS and `xdg-open` on Linux. No other launcher logic. |
| O5 | **Token exposure (minimized, not eliminated).** The link is never printed or written to a file by the script. It is issued by a `docker run --log-driver none` CLI run, so the Docker daemon does not keep it in a container log. It is held in a shell variable, then passed as the launcher's argument, where it is visible in the process list to the same OS user and root while the launcher runs. The browser keeps it in its history. The token is single-use, consumed by the **Sign in** POST and valid for at most 5 minutes (P1.3), so a link left in history is dead. The sign-in page sends `Referrer-Policy: origin` (D-2d), and the service logs fixed lines without query strings (P1.3 E11). |
| O6 | **Unchanged:** the Host/Origin/CSRF guard, session lifetime, cookie scope, `127.0.0.1` binding, and the confirm-then-POST sign-in. `open` only spares the operator the copy and paste. |

## 3. Verification (`scripts/lib/check-open`, host; frozen before implementation)

Run on the host with `scripts/db up` and an installed binary. The check uses its own service
container (`lockstep-open-check`), a free port, and a fresh database `lockstep_open_<stamp>` on the
operator PostgreSQL server, dropped at the end. The browser stand-in is
`scripts/lib/open-smoke-browser`: headless Chromium in the dev image (`test/browser/cdp.py`) on the
host network. It receives the link only as its argument and passes it to the driver on stdin, and
it records only the path, status and page markers of each step, never the link.

| Case | Asserts |
|---|---|
| Refusals | `open --bogus` → 64; `open --port 0` → 64; `open --port 8000 extra` → 64 |
| Database not ready | a configuration naming a missing database → 69 mentioning "not ready", and **no** service container was started |
| Normal flow | nothing running → exit 0; the check container is running; the smoke browser loaded the sign-in page, pressed **Sign in** and reached `/operator` (200, with **Sign out**); a second **Sign in** with the same link is refused with 403, as C-P1.3 E4 specifies (the token is single-use) |
| Already running | `open` again → exit 0; the container's start time is unchanged; a new sign-in succeeds |
| Port mismatch | `open --port <another>` while running → 75 |
| Launcher unavailable | `LOCKSTEP_BROWSER=/nonexistent` → 70 |
| Launcher fails | `LOCKSTEP_BROWSER=false` → 70 |
| No token leaks | no output of any `open` run, and not the service container's log, contains `token=` or a token-shaped value issued in the run |
| Wrapper | `scripts/lockstep workspace show` runs the installed CLI (exit 0, `name:` line) |

Plus, once and by hand: `scripts/lockstep open` with the real default browser on this Mac (O4
without an override). That is the owner's browser, so the agent asks before doing it.

## 4. Allowed paths

`scripts/lockstep` (new), `scripts/service` (the `open` subcommand and its help line),
`scripts/lib/check-open` and `scripts/lib/open-smoke-browser` (new), `README.md`,
`docs/OPERATOR_GUIDE.md`, `docs/gates/P2-open/**`. No Haskell change.

## 5. Freeze record

Frozen 2026-10-18 by the writing agent (manual).

| File | SHA-256 |
|---|---|
| `scripts/lib/check-open` | `48ba100a71af2383f5b7fdd10f687f8fa5f7cec60cbe00924ef85aace6616be7` |
| `scripts/lib/open-smoke-browser` | `0804f4037ad1c8cf083b340d40d64d53e22a8d713608a2299ff1e2c5a303d432` |

Pre-freeze verification:

- Baseline without the implementation (`evidence/prefreeze-baseline.log`): 16 failures. Every
  functional case fails because `scripts/lockstep` does not exist. The 6 passes are absence
  checks (no container started, nothing leaked), and each is paired with a functional case.
- The first baseline run exposed a defect in the check itself (`started_at` aborted under
  `set -e` with no container). It was fixed before the freeze.
- The smoke browser was run against a real throwaway service (port 8093, database created and
  dropped) with a link from `scripts/service cli operator sign-in`. It loaded the confirm page
  (200), signed in to `/operator` (200, Sign out present), and a second Sign in with the same link
  was refused. That run showed the refusal is `403` (C-P1.3 E4), not the `401` the draft check
  expected; the check was corrected before the freeze.
