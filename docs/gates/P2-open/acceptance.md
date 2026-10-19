# `lockstep open` — verification record (C-OPEN@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `0b14997`. One manual step is the owner's:
  `scripts/lockstep open` with the real default browser on this Mac (see §3).
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-18.
- Contract: `contract.md` (FROZEN at `98606ca`).

## 1. Result

`scripts/lib/check-open` at `0b14997` (clean tree): **22/22 PASS**
(`evidence/check-open-results.txt`). It covers refusals (64), the database not ready (69, nothing
started), the normal flow with real headless Chromium reaching `/operator` with **Sign out**, the
single-use link (a second Sign in is refused with 403), an already-running service (not
restarted; its port discovered), a port mismatch (75), an unavailable and a failing launcher
(70), no token in any output, in the smoke summaries or in the service log, and the wrapper
forwarding to the installed CLI. Host shell: macOS bash 3.2.57. Lint and static checks pass.

## 2. Token exposure (measured where possible, as Contract O5 requires)

| Path | Exposure | Measured / basis |
|---|---|---|
| CLI → script | Docker attach stream only; `--log-driver none`, so the daemon keeps no container log (the default driver here is `json-file`) | `docker info` → `json-file`; attached output works with `none` |
| Script | one shell variable, cleared after use; never printed or written | check: no output contains `token=` or a 43-character token-shaped value |
| Script → browser | the launcher's argument (`open URL`): visible in the process list to the same OS user and root while `open` runs | inherent to the OS handoff; not avoidable without changing the guard (a `file://` auto-post would send `Origin: null`, refused by D-2d) |
| Browser | the URL is kept in the browser history | dead after Sign in or after 5 minutes (C-P1.3 E4); check: a reused link is refused |
| Service | fixed log lines, no query strings (C-P1.3 E11) | check: the service log has no `token=` |
| Launcher errors | discarded, because an error message could repeat the URL | by construction |

## 3. Pending: the owner's real default browser

Not run by the agent, because it would open a tab in the owner's own browser and start the owner's
service. Suggested check (about 30 s): `scripts/lockstep open --port 8010`, press **Sign in**, then
confirm `/operator` shows **Sign out**. It uses the installed `6c2851d` binary and the operator
database (schema 5), which `open` only reads.

## 4. Scope kept

No Haskell change. No new authentication, token type, daemon or launcher framework. The guard,
sessions, cookies and the `127.0.0.1` binding are unchanged. Remote access is not addressed (future,
separate security gate).
