# Request — retiring the Phase 1/2 cookie pages (for the owner's decision)

- Status: **AWAITING THE OWNER.** Nothing is retired; the pages and their frozen tests are
  unchanged (owner decision DR-P3.1 §2: "Plan their retirement during P3.4 through separately
  authorized frozen-test amendments").
- From: the writing agent (Implementer), 2026-10-26, with C-P3.4.

## 1. What would be retired

The Phase 1/2 operator pages on the service, signed in with the `lockstep_session` cookie:
`/operator`, `/operator/sign-in` (GET, POST), `/operator/sign-out`,
`/operator/commands/rename-workspace`, `/operator/commands/queue-noop`, `/operator/receipts/<id>`,
`/operator/jobs/new`, `/operator/center`, `/operator/ledger`, and `scripts/lockstep open`.

Why: the cookie is sent by the browser to every service on `127.0.0.1` (Gate A limitation,
accepted for Phase 1 only; confirmed in both browsers, `docs/gates/P3.1/evidence/trust-probe.log`).
Since C-P3.4 the application has its own header-session pages, so an ordinary user no longer
needs the cookie pages; while they exist, anyone who signs in to them holds a leaking cookie.

## 2. What it would amend (exact files; each change is shown to you as a diff before it is made)

| Frozen artifact (freeze record) | Assertions that would change |
|---|---|
| `test/integration/Lockstep/OperatorTrustTest.hs` (C-P1.3 §9.1) | the CLI link format `…/operator/sign-in?token=` (:49-59), the cookie attributes (:101-106), sign-out (:121-125), cookie decoding (:331-353) |
| `test/unit/Lockstep/Web/OperatorRoutesTest.hs`, `RequestGuardTest.hs` (route classes only), `CommandRoutesTest.hs`, `CommandCenterViewTest.hs`, `LedgerPageTest.hs` | the `/operator…` route expectations |
| `test/integration/Lockstep/OperatorCommandTest.hs`, `DispatcherTest.hs`, `CommandCenterTest.hs`, `OperatorLedgerTest.hs` | the cookie sign-in each uses to reach the operation under test (the operations themselves stay, through the CLI or the new application) |
| `test/integration/Lockstep/BrowserFormTest.hs`, `test/browser/cdp.py` | the cookie-page form journey (replaced by the application's browser tests) |
| `test/unit/Lockstep/Foundation/OperatorTokenTest.hs`, `CliOperatorTest.hs` | the CSRF vectors (no longer used) and `operator sign-in` printing a cookie-page link |
| `scripts/lockstep`, `scripts/service` (`open`), `scripts/lib/check-open`, `scripts/lib/open-smoke-browser`, `scripts/b1` (Gate B report r2 §2.1; C-OPEN §5) | `open`, the link regex `…/operator/sign-in\?token=`, the B1 leak check for `lockstep_session=` |

## 3. Options

- **(a) Retire after P3.6** (recommended): once Projects and Tasks exist in the application, the
  cookie pages offer nothing the application lacks except the ledger and command-center views,
  which move to Advanced; one amendment set, reviewed once.
- (b) Retire now: the Phase 1/2 operations would be reachable only from the CLI until P3.6.
- (c) Keep them as a technical fallback until Gate C-UX, under the documented limitation.

## 4. Your decision

| Decision | Choice |
|---|---|
| Retire (a / b / c) | **(c) — defer retirement until after Gate C-UX** (Planner recommendation) |
| Decided by / at | Phase 3 Planner disposition, 2026-10-27 |

Conditions attached to (c), from the disposition:

- No large legacy-route or frozen-test migration during the current qualification.
- Ordinary users are directed only through the header-authenticated application.
- The old cookie routes get no new capabilities.
- The ability to run the deferred Gate B walkthrough in an isolated qualification environment is
  kept.
- Final retirement needs an exact, separately authorized amendment set; this decision is not
  permission to change protected files.
