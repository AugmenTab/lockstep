# Contract — P3.4 Permanent application shell

- Contract ID: `C-P3.4@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.4; PRD v0.3 FR-UX-04 (with FR-APP-05–09); Plan v0.3 §4 P3.4
  ("permanent authenticated Brigid/HTMX application shell; Home/Projects/Tasks/Decisions/
  Activity/Settings/Advanced; govern migration from old cookie pages"); owner decision DR-P3.1
  §1–2 (T8 "the same model for the application" deferred to P3.4; the cookie pages stay until
  separately authorized frozen-test amendments).
- Writer: the single writing agent (Implementer, manual).
- Scope: the shell, its sign-in and hand-over, Home, and honest empty sections. Project creation
  (P3.5), tasks (P3.6), Profiles (P3.7), decisions (P3.8) and the activity view (P3.9) fill those
  sections later and are **not** here.

## 1. What P3.4 delivers

1. **Open Lockstep from the control pane.** An **Open Lockstep** button in the pane (when the
   service runs and answers) opens the application, already signed in, in the same tab.
2. **The application shell** on the service at `/app/…`: one consistent navigation (Home,
   Projects, Tasks, Decisions, Activity, Settings, Advanced) that works with the keyboard and on
   narrow screens; a Home that says what state Lockstep is in, what needs attention and what to
   do next; loading, error and empty states in plain words; the exact technical facts under
   Advanced.
3. **The same trust model as the pane (T2–T7)** for the application: one-time fragment token,
   header session (no cookie), exact Host/Origin, strict CSP, content-free shell.
4. **A written request to retire the Phase 1/2 cookie pages**, with the exact frozen-test
   amendments it needs, for the owner. Nothing is retired in P3.4.

## 2. Decisions

| # | Decision |
|---|---|
| A1 | **Routes on the service.** `GET /app` and `GET /app/<section>` (the seven sections above) and `GET /app/sign-in`: the content-free shell. `GET /app/fragments/<section>`: the section's server-rendered HTML (Brigid), with the session header. `POST /app/api/session` (token body) → `{"session":…}`; `POST /app/api/sign-out`. Static `/static/app.js` and `/static/htmx.min.js`. Everything under `/app` that is not one of these is 404. `/`, `/operator/…` and the C-P1.x routes are unchanged. |
| A2 | **Sessions.** The application's one-time token and session are the C-P1.3 ones (`lockstep_operator_sign_in_tokens`, `lockstep_operator_sessions`, digests only, 5-minute token, 12-hour session): no migration. The session travels only as `X-Lockstep-Session`, set by the page's own script on every HTMX request; it is stored in `localStorage` for the service's origin (`lockstep.app.session`). No cookie is set or read under `/app`. |
| A3 | **Hand-over** (T8, adapted: the pane holds no database credentials). A fourth signed request kind, `lockstep-session-request 1` (`requests/<id>.sreq`), op `open-application`, expect `service-running`. The helper checks the service runs and answers, runs the fixed `scripts/service [--instance N] cli operator sign-in --port P` (P: the running service's port), keeps only the token, and writes it to `pane/handover/<id>` (mode 0600). The pane's `GET /api/handover/<id>` (session) returns it once and deletes the file; the page then navigates to `http://127.0.0.1:P/app/sign-in#<token>`. The token never appears in a result file, a log or an address the server sees. |
| A4 | **HTMX.** `htmx.org` 2.0.4, `dist/htmx.min.js`, vendored at `static/htmx.min.js`, SHA-256 `e209dda5c8235479f3166defc7750e1dbcd5a5c1808b7792fc2e6733768fb447` (identical from unpkg and jsdelivr), 0BSD, recorded in `THIRD_PARTY_LICENSES.md`. Configured by a `<meta name="htmx-config">` with `allowEval: false`, `allowScriptTags: false`, `includeIndicatorStyles: false`, `selfRequestsOnly: true`, so it works under the CSP of T7 (`script-src 'self'`, `style-src 'self'`). |
| A5 | **Home.** From observed facts only: database readiness and schema revision; the workspace name; counts of Tickets and Work Orders from the C-P2.8 projection; what needs attention (a database that is not ready, effects waiting for a human); next actions written as plain sentences. No percentages, ETA, cost or invented progress. |
| A6 | **Empty sections.** Projects, Tasks and Decisions say plainly that they arrive in a later update and what they will do; they have no buttons. Activity shows nothing invented. Settings says where installation and services are managed (the control pane, opened by running `lockstep`). Advanced lists the exact facts (schema revision, version, the session's expiry) and links to the Phase 1/2 pages, labelled as the earlier technical views. |
| A7 | **Interruptions.** A fragment that fails to load says "Lockstep is not answering right now" with a **Try again** button; a `401` shows the signed-out view ("You are signed out. To open Lockstep, run lockstep and press Open Lockstep."). Navigation never leaves a blank page. |
| A8 | **Cookie pages.** Unchanged and still reachable at `/operator…`. `docs/gates/P3.4/retirement-request.md` lists the exact frozen tests and lines that retiring them would amend, for the owner's separate decision. |

## 3. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Foundation/SessionProtocolTest.hs` | unit | the session request kind: vector (`openssl`), allowlist `open-application`, `expect service-running` only, kinds do not mix |
| `test/integration/Lockstep/AppShellTest.hs` | integration, real service and PostgreSQL | every section address returns the same content-free shell with the exact CSP and the pinned HTMX configured without eval; anything else under `/app` 404; the one-time token works once and only from this origin; fragments need the header (a cookie with the session is ignored), exact Host; Home shows observed state and no percentages or ETA; database text escaped; unbuilt sections say "later update" and have no buttons or forms; Advanced shows schema revision and session expiry; sign-out; `/` and `/operator` unchanged; 4 KiB body limit |
| `test/integration/Lockstep/HandoverTest.hs` + `Support/App.hs` | integration: real helper issuing with the real CLI against a real database, real pane, real service; headless Chromium (`test/browser/app_driver.py`, importing the frozen drivers, adding keyboard and viewport steps) | the token lands in a 0600 hand-over file, never in the result or a log, and the service accepts it; no service → nothing issued; the pane hands the address over once, to its own session; a forged hand-over file is not served; the journey: pane → **Open Lockstep** → Home → Tab/Enter to Projects → phone width without horizontal scrolling → a page on another port cannot read the application session → sign-out |

Page wording the tests rely on: the pane's `#open-application` button (shown when the service
runs); Home contains "What needs your attention"; seven `nav a` links; unbuilt sections contain
"later update"; Advanced contains "Schema revision" and "Session expires"; the application's
`#sign-out` button; "You are signed out".

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the shell and hand-over were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/SessionProtocolTest.hs` | `77013dead1845c10b0d6fb48890055a88c4d4ea8b1dcb51c7fffdb80d3c3551d` |
| `test/integration/Lockstep/AppShellTest.hs` | `d35dc52c4917cedcee4f0a5ec8d9cbb5df6f3572d3e00e7202323cbf2e69b667` |
| `test/integration/Lockstep/HandoverTest.hs` | `eb856b5ade7e524d399b448d7203e638e1bcf874dcd726648de01fc61bbcfd6c` |
| `test/integration/Lockstep/Support/App.hs` | `9a9c09c36a70a993ba4c90fac9f7c7d349d93d46683f7bd25cb9fdceffe2864f` |
| `test/browser/app_driver.py` | `d303f93bbb94a44c96fccbdf684049573aa33f9e8ba4351490ffd9823afa81d4` |
| `test/unit/Main.hs` (runner, additive) | `6658ade6dba2fb001175e7a9fbb17c4f185a9d7ab9db468178d1cf7eb35cf9de` |
| `test/integration/Main.hs` (runner, additive) | `edf1371c72122f340d343f0094b4d2151a420c786bcbad78bdb69fb69c6f66f6` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- Unit baseline against the type-only stub (`prefreeze-unit-baseline.log`): 5 of 7 new cases
  fail; the HMAC vector (through C-P3.1 `hmacHex`) and "kinds do not mix" pass. The session codec
  was then implemented before the freeze, as before; all 7 pass.
- `scripts/check --integration` against the pre-P3.4 service, pane and helper
  (`prefreeze-integration-baseline.log`): format, lint, build, unit (742), guard pass; 15 of 295
  integration cases fail, all in the two new groups, each on its behaviour (404 for `/app…`, no
  hand-over result, no Open button); the fixtures ran (database migrate, real service,
  throwaway checkout, helper, pane, the browser up to the pane's "Running"). Two new cases pass:
  "anything else under /app is 404" and "the Phase 1/2 pages and the status page are unchanged".
- A lint hint in `AppShellTest.hs` (eta reduction) was found by the first run and fixed before
  the freeze.
