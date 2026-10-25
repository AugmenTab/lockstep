# Contract — P3.1 Trusted launcher and bootstrap control pane

- Contract ID: `C-P3.1@v1`
- Status: **FROZEN** (2026-10-25; §8)
- Authority: Phase 3 handoff P3.1 (`.local/plans/phase-03.md`); owner decision DR-P3.1 / DG-15
  (`owner-decision.md`); PRD v0.3 FR-UX-01, FR-UX-02, NFR-16; Plan v0.3 §4 P3.1 and §4.1.
- Writer: the single writing agent (Implementer, manual).
- Scope rule (Plan v0.3 §3): P3.1 only. Start/Stop/Restart buttons (P3.2), install/upgrade/
  migrate (P3.3) and the application hand-over (T8, P3.4) are **not** in this Contract.

## 1. What P3.1 delivers

1. A root launcher `./lockstep` that works from any directory (also through a symlink on the
   PATH), starts or reconnects to the control pane, starts already-compatible services, and opens
   the default browser already signed in.
2. A control pane: `lockstep control serve`, run in container `lockstep-control` with no Docker
   socket, no database credentials and no source tree. It shows the installation, service and
   database state in plain language, and works when PostgreSQL or the service is down.
3. A host helper `scripts/control-helper`: the user's own process, which runs one versioned,
   allowlisted operation (`status`) for the pane through an authenticated file channel.
4. The approved trust model T1–T7 (`design-request.md` §2, amended by `owner-decision.md`).

## 2. Decisions within the approved design

| # | Decision |
|---|---|
| L1 | **Files.** New: `lockstep` (root), `scripts/control-helper`, `static/control.js`, Haskell modules `Lockstep.Foundation.ControlProtocol`, `Lockstep.Application.ControlPane`, `Lockstep.Web.Control`. Changed: `Lockstep.Foundation.Cli` (one command), `app/lockstep/Main.hs`, `Lockstep.Web.Static` (one asset), `static/lockstep.css` (control-pane classes), `package.yaml` (test dependencies only), the two test runners (additive). Frozen scripts and tests: unchanged. |
| L2 | **State root.** `.local/control/` (mode 0700), or `.local/control-NAME/` for `--instance NAME`. Inside: `pane/` (the only writable directory the pane container mounts, at `/state`), `helper/` (helper-only) and `install/` (the pane binary and its `VERSION`, mounted read-only). An instance therefore has its own pane build and never uses the operator's. |
| L3 | **Ports.** Pane: 8100 by default (`LOCKSTEP_CONTROL_PORT` overrides); if the port answers and is not this installation's pane, the launcher tries the next nine ports and records the chosen port in `STATE/port`. Service auto-start uses port 8000 (`LOCKSTEP_SERVICE_PORT` overrides). |
| L4 | **Pane identity.** At pane start the launcher writes a random `pane/pane.id`. `GET /api/health` returns `204` with `X-Lockstep-Control: <pane.id>`. The launcher sends a sign-in link only to a port whose health identity matches, so a squatter on the port never receives a token. |
| L5 | **Sign-in token** (T2). 32 random bytes as 43-character base64url; the launcher writes only `pane/signin/<sha256-hex of the token text>` (mode 0600, content `expires <unix-seconds>`, 300 s), and opens `http://127.0.0.1:<port>/sign-in#<token>`. The pane consumes the file by removing it; a second exchange finds nothing. |
| L6 | **Session** (T3). 32 random bytes, base64url, sent by the pane's script as `X-Lockstep-Session`. The pane keeps only SHA-256 digests in memory, with a 12-hour absolute expiry, at most 16 sessions (oldest dropped). Sign-out, `lockstep stop` and a pane restart end every session. |
| L7 | **Channel** (B-a amended). Request files `pane/requests/<id>.req`, result files `pane/results/<id>.res`, both written atomically (temporary name, then rename), both authenticated with HMAC-SHA256 under a 32-byte per-helper-session key written by the launcher to `pane/channel.key` and `helper/channel.key` (mode 0600). Format: §4. |
| L8 | **Helper.** Bash, run by the launcher in the background as the invoking user (`nohup`), one at a time (lock directory with PID), one request at a time (serialized), bounded by a timeout (90 s; `LOCKSTEP_HELPER_TIMEOUT`, 1–300 s, may change it). It journals `start` before and `end` after every operation in `helper/journal`, writes the result before the journal `end`, and on start marks any operation that has a `start` and no `end` as `interrupted`. It records each accepted request id in `helper/seen` before running it. |
| L9 | **Allowlist v1.** `status` with `expect any`. It reads the installation's `VERSION` file and runs only `docker container inspect` (service and database containers) and `scripts/service [--instance NAME] cli db status`, with fixed arguments. Every result value is constrained (§4); free text appears only in `detail`, reduced to printable ASCII and at most 300 characters. |
| L10 | **Pane container.** `docker run --detach --name lockstep-control[-NAME] --network host --user <uid>:<gid> --read-only --cap-drop ALL --security-opt no-new-privileges --volume STATE/install:/opt/lockstep-control:ro --volume STATE/pane:/state lockstep-dev:p1 /opt/lockstep-control/bin/lockstep control serve --port P --state /state`. No other mount, no environment carrying a database configuration. |
| L11 | **First launch.** If `STATE/install/bin/lockstep` is missing, the launcher says so in plain words ("Preparing Lockstep for first use …") and builds it once (`docker build` of the dev image and `stack build --copy-bins` into `STATE/install`, with `VERSION`), logging to `STATE/install/build.log`. It never rebuilds otherwise; `lockstep rebuild-pane` rebuilds on request. |
| L12 | **Auto-start** (A). Operator mode: if `.local/install/bin/lockstep` and `.local/config/lockstep.json` exist, `scripts/db up`, then `scripts/service cli db status`; only on `readiness ready …` (schema equals the binary's revision) and no running service, `scripts/service start --port <service port>`. Instance mode: the same through `scripts/service --instance NAME`, and the database container is not managed. Nothing is migrated, installed or upgraded. A failure here never prevents the pane from opening. |
| L13 | **Concurrency.** The launcher holds `STATE/launch.lock` (a directory, with PID; a lock whose PID is gone is removed) for its whole run; a second launch waits up to 120 s and then reconnects. A running, healthy pane and helper are reused, not restarted. |
| L14 | **Browser.** `LOCKSTEP_BROWSER` (one command, given the URL) if set, else `open` (macOS) or `xdg-open` (Linux). Its output is discarded. On failure: exit 70 with a plain message and no token. |
| L15 | **`lockstep stop`.** Stops the pane container and the helper (SIGTERM; the helper finishes its current operation, bounded by its timeout), removes the channel keys and unused sign-in files. It does not stop the service or the database, and says so. |
| L16 | **PATH** (P amended). `lockstep setup-path` (and, once, the first interactive launch) asks before each change: a symlink `~/.local/bin/lockstep` (never replacing an existing file it did not create), then, if `~/.local/bin` is not on the PATH, one marked line in the start-up file of the user's actual shell from `$SHELL`: zsh `~/.zprofile`; bash `~/.bash_profile` on macOS, `~/.bashrc` on Linux. For any other shell it prints the exact line to add and changes nothing. Declining changes nothing. |
| L17 | **Forwarding** (N). `lockstep ARGS…` other than `stop`, `setup-path`, `rebuild-pane` and `help` runs `scripts/lockstep ARGS…` unchanged (frozen). `lockstep --instance NAME` selects the instance for the launcher; with further arguments it forwards `scripts/lockstep --instance NAME …`. |

## 3. HTTP surface of the pane (T4–T7)

Bound to `127.0.0.1` only. Every response: `Cache-Control: no-store`, `X-Content-Type-Options:
nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy:
same-origin`, `Cross-Origin-Resource-Policy: same-origin`, and
`Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`.
No response carries `Access-Control-Allow-*` or `Set-Cookie`.

| Route | Guard | Behaviour |
|---|---|---|
| `GET /`, `GET /sign-in` | public read (C-P1.3 E7 `PublicRead`) | the content-free shell: no state, no data, loads `/static/control.js` |
| `GET /static/control.js`, `GET /static/lockstep.css` | public read | embedded assets |
| `GET /api/health` | public read | `204`, `X-Lockstep-Control: <pane.id>` |
| `POST /api/session` | exact Host and Origin | body: the token text. `200` `{"session":"…"}`, or `403` (unknown, expired, used, malformed, not a regular file) |
| `POST /api/sign-out` | exact Host and Origin, session | `204`; the session ends |
| `POST /api/requests` | exact Host and Origin, session | body: an allowlisted operation name. `202` `{"id":"…"}`; unknown operation `400` |
| `GET /api/requests/<id>` | exact Host, session | `200` `{"state":"pending"}`, or the verified result; a result whose MAC fails is `{"state":"untrusted"}` |
| anything else, any method (including `OPTIONS`) | — | `404` (`405` for `OPTIONS` on a known route), never CORS headers |

A missing, malformed, unknown or expired session is `401` with no data. Bodies over 4 KiB are
refused (`413`). The pane reads no database configuration and needs no PostgreSQL.

The page shows, in plain words: "Application" (`Installed` with the short commit, or `Not
installed yet`), "Service" (`Running`, `Not running`, `Not set up`), "Database" (`Ready`, or `Not
ready` with a plain reason), the time of the check, a **Check again** and a **Sign out**
(`#sign-out`) button, and the raw fields under **Technical details**. Without a session it shows
"You are signed out of this window. To open Lockstep, run lockstep on this computer." and no
data. A used or expired link says it was "already used or has expired". One status check is made
per page load; Sign out reloads the page.

The page script (`static/control.js`) removes the fragment from the address bar and the current
history entry before anything else (`history.replaceState`), exchanges the token, stores the
session in `localStorage` for this origin only, and renders every value with `textContent` (no
`innerHTML`, no inline script, no `eval`).

## 4. Channel protocol v1

Request (`requests/<id>.req`, at most 1024 bytes, printable ASCII lines):

```
lockstep-control-request 1
id <32 lower-case hex>
issued <unix seconds>
op <operation>
expect <expected state>
mac <64 lower-case hex>
```

Result (`results/<id>.res`):

```
lockstep-control-result 1
id <id>
op <operation>
outcome ok|refused|failed|timed-out|interrupted
reason <code>|-
started <unix seconds>
finished <unix seconds>
field <name> <value>        zero or more; name [a-z][a-z.]*, value [A-Za-z0-9._:-]{1,80}
detail <0-300 printable ASCII characters>
mac <64 lower-case hex>
```

`mac` is HMAC-SHA256, keyed by the 32 bytes of `channel.key` (64 hex characters), over every
byte before the `mac` line. The helper accepts a request only if: it is a regular file (not a
symlink) owned by the user, not group- or world-writable, at most 1024 bytes; its name is
`<id>.req` and matches its `id` line; every line is in this order and form; the version is `1`;
the MAC verifies; the id was never seen; `issued` is within 120 s in the past and 10 s in the
future; the operation is allowlisted; and `expect` is valid for it. Refusal codes: `malformed`,
`bad-version`, `bad-mac`, `replayed`, `stale`, `unknown-op`, `bad-expect`, `not-regular-file`,
`not-owner`, `bad-permissions`, `too-large`. A refusal writes a signed result only when the file
name is a valid `<id>.req` and no result exists yet; a replay leaves the first result unchanged
and is journaled. The helper never overwrites a result, refuses to use a `requests` or `results`
directory that is a symlink, and never follows a symlink when writing a result. Files whose names
start with `.` (the pane's temporary files) and names that are not `<id>.req` are left alone or
removed without a result.

Fields of `status`: `install.present` (yes|no), `install.commit`, `install.dirty`,
`service.state` (running|stopped|absent|unknown), `database.server`
(running|stopped|absent|not-managed|unknown), `database.readiness` (ready|not-ready|unknown),
`database.reason`, `database.revision`, `database.pending`, `helper.protocol` (1).

## 5. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Foundation/ControlProtocolTest.hs` | unit | request/result encoding, HMAC and digest vectors computed independently (`openssl dgst -sha256 -mac HMAC`, `shasum -a 256`), strict parsing and every malformed form, the allowlist |
| `test/unit/Lockstep/Foundation/CliControlTest.hs` | unit | `control serve` parsing and refusals |
| `test/integration/Lockstep/ControlPaneTest.hs` | integration, real binary | headers and exact CSP; shell has no data; unknown routes 404; OPTIONS without CORS; Host/Origin refusals (foreign, `localhost`, `null`, missing); token: unknown, malformed, expired, replayed, concurrent double exchange, symlinked sign-in file; sessions: missing, wrong, expired-by-sign-out, revoked; request files carry a MAC the test verifies; forged result shows `untrusted`; the pane runs with no database configuration at all |
| `test/integration/Lockstep/ControlHelperTest.hs` | integration, real `scripts/control-helper`, `docker` replaced by a test stub on `PATH` | valid request → MAC-verified result with the status fields; forged MAC, replayed file, stale and future `issued`, unknown operation, bad `expect`, malformed lines, wrong name, oversize, symlinked request, request owned by another user, group-writable file; symlinked `requests` directory not read; symlink at the result path not followed; shell metacharacters inert; two requests serialized (journal intervals do not overlap); timeout (`timed-out`, process group killed); interrupted operation reported after restart; a second helper refuses to start; markup in docker output reaches `detail` only as constrained text |
| `test/integration/Lockstep/Support/Control.hs`, `test/browser/control_driver.py` | test support | the throwaway checkout, `docker` stub and process helpers; a driver that imports the frozen `cdp.py` unchanged and adds `wait_text`, `eval` and `sleep` steps |
| `test/integration/Lockstep/ControlBrowserTest.hs` | integration, headless Chromium | fragment sign-in; the address bar no longer has the fragment; status rendered from the real helper; reload keeps the session; a page on another port cannot read the session, cannot send the header (preflight refused), and its plain POST is refused; markup from the helper is shown as text; the same link a second time is refused; sign-out ends the session |
| `test/integration/Lockstep/LauncherTest.hs` | integration | `lockstep help` through a symlink from another directory names the checkout; `setup-path`: yes/no for zsh and bash, other shell prints the line only, an existing foreign `~/.local/bin/lockstep` is left alone, a second run changes nothing |
| `scripts/lib/check-control` + `scripts/lib/control-smoke-browser` | host, real Docker (instance `p31c`, its own database on the operator PostgreSQL server, its own ports; removed at the end) | first launch with the database missing: pane opens, status says not ready, no service started, nothing migrated; schema behind: not started, not migrated; compatible and stopped: started; real browser signs in through the launcher; second launch reuses pane and helper (start times unchanged) and does not rebuild; two simultaneous launches give one pane container and one helper; port squatter skipped; browser failure exits 70 without a token; pane container: no Docker socket, only the two mounts, read-only, the user's uid; `stop` ends pane and helper and the old session is refused; forwarding to `scripts/lockstep`; no token in any output or log |

Plus `scripts/check --integration`, a Linux clean clone, and, once and by hand with the owner's
consent, `./lockstep` with the default browser on this Mac.

## 6. Exposure that remains (stated, not hidden)

- The one-time token is in the browser launcher's arguments while `open`/`xdg-open` runs. On
  macOS `ps` shows other users' arguments too, so for that instant any local account could read
  it; it is single-use, expires within 5 minutes and is normally consumed within a second. This
  corrects `design-request.md` §2, which said only "your OS user and root".
- The browser history keeps the `/sign-in#…` entry only until the page replaces it; a link
  copied before that is dead after first use.
- Whoever runs as the user (or root) can read `.local/control` and the browser profile (T1).
- A `docker run --rm` started by `status` keeps running if the helper is killed mid-operation;
  it is a read-only `db status`.

## 7. Allowed paths

The files of L1, `scripts/lib/check-control`, `scripts/lib/control-smoke-browser`, the test files
of §5 and their fixtures, `README.md`, `docs/OPERATOR_GUIDE.md`, `docs/gates/P3.1/**`.

## 8. Freeze record

Frozen 2026-10-25 by the writing agent (manual), before the pane, the helper and the launcher were
implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/ControlProtocolTest.hs` | `798d39a880ac6b14c8b8aab68590a79d5ba5924d860095a23268e36d302a9559` |
| `test/unit/Lockstep/Foundation/CliControlTest.hs` | `886c850edaef78f276bbb66e8ea4ddad2a96b9be8ee967f88190adb3ab00b508` |
| `test/integration/Lockstep/ControlPaneTest.hs` | `0033b7c4ed710dd6c9db24dd79a86dadb418397540262a88f284907d470b6eb2` |
| `test/integration/Lockstep/ControlHelperTest.hs` | `0a60bfef56af4ed9469b738e075d87e1791f925672ebfaec4d3824a8939ab676` |
| `test/integration/Lockstep/ControlBrowserTest.hs` | `c30389d69fb188e793ae9c81bb1fccc5324f84c25a5a73c968369f94a504bb5e` |
| `test/integration/Lockstep/LauncherTest.hs` | `ba47af53a6ad6e3ede581ee75ad73372a1eed1f27ede4ac027b68f3d280a8fa2` |
| `test/integration/Lockstep/Support/Control.hs` | `8efedd6be4c4476c44f991d3cd1bca00d683ca1de726fea470e0ee3e0db5faf8` |
| `test/browser/control_driver.py` | `d7e8e9d6b0bbcacc54343040d8959503abecb64042e0324cc6b24f9dcd18faa9` |
| `scripts/lib/check-control` | `0b74b66de79c2d9110cbd57f6d515d411b93a6a5c4f0942ad873f4fee0473940` |
| `scripts/lib/control-smoke-browser` | `1743686e02437922ce74f3b63eb3f725ce74a890775665096f95a99e0ab7d08f` |
| `test/unit/Main.hs` (runner, additive) | `322c7ed9171ea12f1c3163f16831661e96c76d44be13293b2225e399120e02df` |
| `test/integration/Main.hs` (runner, additive) | `20421d5cd6bcb4f42048c33f8a6c171fced6edd3b1c527bd3308ceafd3da5227` |

Pre-freeze verification (logs in `evidence/`):

- **Build:** library and both suites compile under `--pedantic`; fourmolu and hlint clean on every
  new file.
- **Unit baseline against type-only stubs** (`prefreeze-unit-baseline.log`): 28 of 712 fail, all
  in the two new groups; the 678 earlier tests pass. Six new cases pass against the refusing
  stubs: the key's `Show` redaction, the default port 8100, and four refusal cases (malformed
  requests, missing/extra MAC line, bad field values, bad detail) that a refusing stub satisfies;
  each is paired with a positive case that failed.
- **The codec was then implemented before the freeze**, to let the integration fixtures run
  (they compute sign-in digests, request ids and MACs through it). With it, all 34 new unit cases
  pass; the HMAC vectors it reproduces were computed beforehand with `openssl`, independently of
  this code. No unit test was changed after that.
- **Integration fixtures exercised against a scaffold** (not committed: a pane that answers only
  `/api/health`, a helper that does nothing, a launcher that exits 1;
  `prefreeze-integration-scaffold.log`, `prefreeze-browser-scaffold.log`): every case reached its
  behavioural assertion. 4 of 48 pass against the scaffold: `/api/health`, unknown routes 404
  (both genuinely served by the scaffold), and two helper absence checks (a symlinked `requests`
  directory is not read; a symlink at the result path is not followed), each paired with positive
  helper cases that failed. The browser test ran its first half to the end (sign-in page, reload,
  the hostile page on another port) and failed on the missing Sign out button.
- **Host check exercised against the scaffold** (`prefreeze-check-control-scaffold.log`): it ran
  every case to the end and cleaned up (no instance files or containers left); 38 failures.
- Defects found and fixed in the tests during this work, before the freeze: the setup depended on
  the stubbed codec (sign-in file named by an empty digest); the driver's `eval` aborted on a page
  that throws (now reported as a value); the host check aborted under `set -e` at the first
  unreachable step and had three comparisons that passed when both sides were `none`; the
  timed-out-process check counted a zombie as running.
