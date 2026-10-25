# DR-P3.1 — Bootstrap trust model: security-design decision request

- Status: **AWAITING THE OWNER.** Nothing below is decided, and no P3.1 Contract is frozen.
- From: the writing agent (Implementer), 2026-10-25, on branch `phase-3`.
- Authority for the stop: Phase 3 handoff (`.local/plans/phase-03.md`, sha256 `d6dafdf2…d0c8`)
  §4.1 ("document and test the concrete trust model … stop with a specific security-design
  decision request rather than implementing an approximation") and §7 ("If a concrete security
  design requires changing an accepted policy or frozen artifact, submit the exact decision or
  amendment request").
- Evidence: `docs/gates/P3.1/evidence/trust-probe.log` (real Chromium 156 and Firefox ESR 153;
  probe `trust-probe-server.py`, `trust-probe-run.sh`).

## 1. Why this needs you

The handoff asks for a pane that runs while PostgreSQL and the service are down, starts and
stops services, installs, upgrades and backs up, and signs the operator in without copying a
token. Three things in the current design stand in the way, and each one is a recorded rule I
may not change on my own:

1. **Where the pane can run.** The `lockstep` binary runs only inside Linux containers; the host
   has only Docker and Git (operator guide §1). A web server that can start and stop containers
   needs Docker's authority, which is equivalent to your OS user on this Mac and to root on Linux.
   That is either a privileged web server or a new host-side helper process. The standing
   instructions say "no new daemon" (`.local/retros/awareness-launch-experience.md` §4), and
   the handoff forbids a privileged general-purpose daemon.
2. **The session cookie leaks to other local services.** This is the Gate A limitation that you
   accepted for Phase 1 only ("must be addressed before consequential agent execution"); the
   handoff now requires it fixed before management controls. The probe confirms it in both
   browsers: a cookie set by `127.0.0.1:8521` was sent to the unrelated service on
   `127.0.0.1:8522` (log lines 9 and 36). Fixing it means a different credential, so it is a
   second sign-in mechanism next to the frozen C-P1.3 cookie ("no second authentication system",
   same note), unless the old one is retired, which amends frozen tests.
3. **The frozen launch scripts.** `scripts/service` and `scripts/lockstep` are frozen at their
   owner-approved digests (Gate B report r2 §2.1), and `scripts/lib/check-open` and `scripts/b1`
   depend on them.

## 2. The trust model I propose (decision S)

| # | Rule |
|---|---|
| T1 | **Trust anchor:** the OS user who can run `lockstep` and write the `0700` directory `.local/` (unchanged from C-P1.3 E1: whoever can read the `0600` config is the operator). Same-user malware is out of scope, as today. |
| T2 | **Sign-in without copying:** the launcher makes a 32-byte one-time token, writes only its SHA-256 into `.local/control/sign-in/` (`0600`, valid 5 minutes) and opens `http://127.0.0.1:<pane>/sign-in#<token>`. The token is in the URL **fragment**, which the browser never sends: in the probe it appeared in no request line, no `Referer` and no log line except the exchange body (0 occurrences, both browsers). The page's own script removes the fragment from the address bar and history entry, then posts the token with the exact `Origin`. The pane consumes the digest once, atomically, and answers with a session secret. |
| T3 | **The credential is not a cookie.** The session secret lives in the browser's `localStorage` for exactly `http://127.0.0.1:<pane>`. Storage is per origin, and the port is part of the origin, so the other service read `null` (log lines 10 and 37). Only the pane's own same-origin script sends it, as the header `X-Lockstep-Session`, on every request that returns data or performs an operation. The server stores only its digest, with a 12-hour absolute expiry; sign-out and `lockstep stop` revoke it. It survived a browser restart in both browsers (lines 24–26, 51–53); a plain session cookie did not. |
| T4 | **No ambient authority, so no CSRF.** The browser never attaches the credential by itself. A page on another port that tried to send the header got only a CORS preflight, which the pane refuses, and the real request was never sent (lines 12–14, 40–41). A plain cross-origin POST did reach the pane, but without the header and with a foreign or `null` `Origin`, and was refused (lines 15–16, 42–43). The exact-`Host` and exact-`Origin` rules of C-P1.3 E7 (D-1a, D-2d) stay as they are: no `localhost`, no `null` exception. |
| T5 | **Pages without a session show nothing.** Every page address returns a content-free shell that loads the content with the header, so data never reaches a request without it. A missing, expired or revoked session gets "Open Lockstep by running `lockstep`", never data. |
| T6 | **Fail closed:** unknown routes 404; missing or wrong header 401; a token that is malformed, unknown, expired or already used is refused without echo; a replayed exchange creates nothing; an unexpected method or a CORS preflight is refused. |
| T7 | **Content Security Policy:** `default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`. No inline script, so an injected `<script>` does not run. |
| T8 | **The same model for the application.** The service's new Phase 3 pages (Home, Projects, Tasks, Decisions, Activity, Settings, Advanced) use T2–T7 on their own port. The pane hands you over by issuing a one-time application sign-in token through the existing `lockstep_operator_sign_in_tokens` table (C-P1.3, no migration) and sending the browser to `http://127.0.0.1:<app>/sign-in#<token>`. |

What it does not defend, stated plainly:
- Whoever runs as your OS user, or as root, can read the browser profile, `.local/` and the
  database password. That is the trust anchor, as before.
- The one-time token is visible to your OS user and root in the process list while `open` runs,
  and the browser's history keeps it. It is single-use and expires within 5 minutes (as C-OPEN).
- A script injected into the pane's own origin could read `localStorage`. T7 and the existing
  escaping rules are the defence.
- If the browser loses its storage (private window, cleared data), you are signed out; running
  `lockstep` again signs you in.
- Safari was not probed (no Safari on Linux). Chromium and Firefox were. Per-origin storage and
  CORS preflight are web-platform rules every current browser follows; your own walkthrough
  (Gate C, C1 and C8) is the check in your default browser.

**Decision S — the browser credential:**
- **(a) Recommended:** T1–T8, with no cookie on any Phase 3 page.
- (b) A dedicated loopback hostname (Gate A option (c)): an `/etc/hosts` name per machine. It
  needs administrator rights once per machine, changes D-1a, and still leaks to any other
  service that uses the same name.
- (c) Keep cookies on Phase 3 pages. The handoff rules this out for management controls.

## 3. The existing cookie sign-in (decision L)

The Phase 1/2 pages (`/operator`, `/operator/center`, `/operator/ledger`, `/operator/jobs/new`,
receipts) and their cookie sign-in are covered by frozen tests (§6).
- **(a) Recommended for P3.1:** leave them and their tests untouched. The new launcher never
  issues a link for them, so an ordinary user never holds the cookie. They stay reachable as an
  advanced path (`scripts/service cli operator sign-in`, `scripts/lockstep open`) under the
  documented Phase 1 limitation. Their retirement comes to you as an exact amendment request
  at P3.4, when the new pages replace them.
- (b) Retire them in P3.1, with exact amendments of the frozen tests in §6 for your approval
  before the P3.1 freeze.

## 4. Where the pane runs and what authority it holds (decision B)

- **(a) Recommended: a pane without Docker authority, plus a narrow host-side helper.**
  - The pane (`lockstep control serve`, the same binary) runs in container `lockstep-control`
    on `127.0.0.1`. It mounts no Docker socket and no source tree, only `.local/control/`
    (read-write) and the database config (read-only, for readiness and the hand-over in T8).
  - The helper (`lib/control-helper`, a shell script) runs as your OS user. `lockstep` starts it
    in the background, and it stops on `lockstep stop`. It runs **only** a fixed list of
    operations, one at a time. Each one calls the existing scripts with fixed arguments:
    start/stop/restart the database or the service; check status; back up; build into a staging
    install; migrate with that backup; activate; verify. The pane can only ask for an operation
    by its name, from that list. A port is the only value that passes through, and it is
    checked as a number. No text from the browser reaches a shell.
  - So a fault in the web-facing process can, at worst, ask for an allowlisted operation.
- (b) The pane holds the Docker socket and runs the same allowlist itself. One process fewer,
  but a web server with your user's authority on this Mac, and root's on Linux.
- (c) No long-running pane: management only in the terminal. This contradicts the handoff.

Both (a) and (b) are a new long-running local process, which the "no new daemon" note excluded.
Under (a) it is the pane plus the helper; neither runs as root, and both stop on `lockstep stop`.

## 5. Smaller choices, each with a recommendation

| # | Question | Recommended | Alternative |
|---|---|---|---|
| R | **First run on a machine with nothing built.** The pane is a compiled program, so the very first `lockstep` must build it before any page exists (several minutes, once). | The terminal shows plain progress ("Preparing Lockstep for first use. This happens once and takes several minutes."), then opens the browser. Everything after that (database, install, upgrades) happens in the browser. | Open the browser at once on a local progress page that refreshes itself, then switch to the pane. |
| P | **Putting `lockstep` on the PATH.** | The first `./lockstep` in the checkout asks once, then links `~/.local/bin/lockstep` to it. If that directory is not on your PATH, it shows the exact line it would add to `~/.zprofile` and adds it only if you say yes. | Only print instructions. |
| A | **Automatic start.** | When the installed version matches the database schema, `lockstep` starts PostgreSQL and the service without asking: no build, no migration, no upgrade. Install, upgrade, migrate and restore always wait for a button press that shows what will happen. | Start nothing until you press Start. |
| N | **New launcher file.** `scripts/lockstep` is frozen. | A new `./lockstep` at the repository root. `lockstep` with no arguments runs the launcher; `lockstep stop` stops the pane, helper and service; any other arguments are passed to the frozen `scripts/lockstep` unchanged. No frozen script changes. | Amend `scripts/lockstep` (exact diff for your approval). |
| H | **HTMX.** The accepted stack names HTMX, but it is not vendored yet. | Vendor one pinned `htmx.min.js` (0BSD, on the license allowlist) with its SHA-256, listed in `THIRD_PARTY_LICENSES.md`. It is one download. | A small first-party script instead. |

## 6. Frozen artifacts

Under the recommended choices (S-a, L-a, B-a, N), **no frozen file changes in P3.1.**

### 6.1 Frozen artifacts that bear on this design and stay byte-identical

Digests are the latest in each freeze record (superseded ones in brackets).

| Area | Frozen files (freeze record) | What they pin |
|---|---|---|
| Cookie sign-in | `OperatorTrustTest.hs` (C-P1.3 §9.1, `604a78ff…`), `OperatorTokenTest.hs`, `OperatorRoutesTest.hs`, `CliOperatorTest.hs`, `Support/Http.hs` (C-P1.3 §8) | exactly one `lockstep_session` Set-Cookie (`HttpOnly`, `SameSite=Strict`, `Path=/`, `Max-Age=43200`, not `Secure`); the CLI link `http://127.0.0.1:<port>/operator/sign-in?token=<43>`; confirm page and POST exchange; fixed CSRF HMAC vectors |
| Cookie use by later tests | `OperatorCommandTest.hs`, `CommandRoutesTest.hs` (C-P1.4), `DispatcherTest.hs` (C-P1.5 §9.1), `CommandCenterTest.hs`, `CommandCenterViewTest.hs` (C-P1.6), `OperatorLedgerTest.hs`, `LedgerPageTest.hs` (C-P2.8) | each signs in through the CLI link and derives `csrf` from the cookie value |
| Browser | `BrowserFormTest.hs`, `test/browser/cdp.py`, `Dockerfile` (C-P1.7-R1) | `/operator` CSP exactly `frame-ancestors 'none'`, `X-Frame-Options: DENY`, Referer and `Sec-Fetch-Site` rules, the "not from this session" CSRF refusal |
| Request guard | `RequestGuardTest.hs` (C-P1.3) | exact Host and Origin on port 8000, no `localhost`, no `null` |
| Public status page `GET /` | `ApplicationTest.hs`, `ServerTest.hs`, `ProcessTest.hs` (C-P1.1), `LivenessPageTest.hs`, `ReadinessRouteTest.hs`, `ServiceDbTest.hs` (C-P1.2 §9.1) | `/` stays the public liveness/readiness page; default port 8000 |
| Scripts | `scripts/service` (`464795be…`), `scripts/lockstep` (`84367c9b…`), `scripts/b1` (`07250cbe…`) (Gate B report r2 §2.1); `scripts/lib/check-open`, `scripts/lib/open-smoke-browser` (C-OPEN §5); `scripts/lib/check-db-backup-restore` (C-P1.2) | the CLI sign-in link regex, `lockstep open`, the B1 leak check for `lockstep_session=` |

Two consequences for C-P3.1 that follow from this table, under the recommended choices:
- **The new application Home cannot be at `/`.** `/` is pinned as the public status page, so
  the new pages get their own paths (for example `/app/…`) until you decide otherwise; moving
  Home to `/` would amend the `GET /` tests above.
- **The new routes must not collide** with any pinned `/operator/…` route, and the request guard
  rules in `RequestGuardTest.hs` apply to them unchanged.

Not frozen in any record: `scripts/a1` and `scripts/check`. The test runners
(`test/unit/Main.hs`, `test/integration/Main.hs`) were last digested in C-P2.9-R1 §4.1; later
addenda added runner lines without a new digest and §4.7 calls the unit runner "not a frozen
file". I will only add lines to them (the "additive only" rule, C-P1.2 §9.2 A3) and record the
new digests in C-P3.1.

### 6.2 What L-b (retire the cookie pages now) would amend

Every row of §6.1 except "Request guard" and "Public status page": the cookie assertions in
`OperatorTrustTest.hs` (:101-106, :125, :228-230, :331-353), the cookie parse in the four later
integration tests, the CSRF vectors and form fields (`OperatorTokenTest.hs:63-85`,
`BrowserFormTest.hs:147-187`), the confirm-page CSP (`OperatorRoutesTest.hs:82-83`), the CLI link
format (`OperatorTrustTest.hs:49-59` and five parsers), and the link regex and leak check in
`scripts/service:261`, `scripts/b1:51,392-393,427`, `scripts/lib/check-open:76-80` and
`scripts/lib/open-smoke-browser:38-40`. Each would come to you as an exact diff before the
P3.1 freeze. That is why L-a is recommended for P3.1, with retirement proposed at P3.4.

## 7. What happens after your decision

1. I write Contract C-P3.1 from your choices (launcher, pane, helper, sign-in, request guard),
   build and run its fixtures, freeze the tests with their digests, implement, and run
   `scripts/check --integration`, a Linux clean clone and real-browser tests. The tests cover a
   missing database, a stopped service, simultaneous launches, a browser that fails to open,
   hostile local pages, forged requests, invalid sessions, CSRF, Host and Origin, and token
   replay (handoff P3.1).
2. Nothing touches your installation (`.local/install`, schema 5) or your database. Tests use
   their own containers, ports and databases.
3. I continue with P3.2 onwards without asking again unless another decision of this kind comes
   up.

## 8. Your decision (to be filled in by you)

| Decision | Choice |
|---|---|
| S — browser credential (a / b / c) | |
| L — existing cookie pages (a / b) | |
| B — where the pane runs (a / b / c) | |
| R — first run (recommended / alternative) | |
| P — PATH (recommended / alternative) | |
| A — automatic start (recommended / alternative) | |
| N — new launcher file (recommended / alternative) | |
| H — HTMX (recommended / alternative) | |
| Decided by / at | |
