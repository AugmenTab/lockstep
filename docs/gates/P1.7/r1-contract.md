# C-P1.7-R1 — Remediation: browser form submissions (Gate A)

- Contract ID: `C-P1.7-R1@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `e9f5791` (R-P1.3-1 applied and re-frozen).
- Authority: the Planner's Gate A decision (Option A) and the owner's R-P1.3-1 approval, both
  verbatim in `docs/gates/A/r2/browser-forms-regression.md`. Executed by the writing agent
  (Implementer) without further approval requests unless a new authority, security or
  verification conflict arises.
- Failure being remediated: in a real browser, no operator form could be submitted
  (`Origin: null` from `no-referrer` pages; refused by the strict guard). Every earlier check used
  curl or http-client with an explicit `Origin`.

## 1. Decisions

| # | Decision |
|---|---|
| R1 | **Headers.** `GET /operator` (200) and `GET /operator/jobs/new` (200) send `Referrer-Policy: origin`. The sign-in confirm page stays `origin`. Every other operator response (receipt pages, command center, refusal pages, 303 redirects) keeps `no-referrer`. `no-store`, `frame-ancestors 'none'` and `X-Frame-Options: DENY` are unchanged. The guard is unchanged: exact Host, exact Origin on every non-GET/HEAD request, no `null` exception. |
| R2 | **Dev image.** One `RUN` layer appended to `Dockerfile` installs Debian bookworm's `chromium` and `python3`. They are test tooling only: the shipped `lockstep` binary links neither and runs without them (`scripts/service` mounts only the binary and its config). The installed Chromium version is recorded in the evidence. |
| R3 | **Browser driver** `test/browser/cdp.py` (Python 3 standard library only): starts headless Chromium with a private profile and drives it through the Chrome DevTools Protocol. Pages are opened with `Page.navigate`. Text is typed with focus plus `Input.insertText`. Buttons are pressed with real mouse events (`Input.dispatchMouseEvent` at the element's centre). Every request the browser itself sends is recorded from `Network.requestWillBeSentExtraInfo` (method, URL, `Origin`, `Referer`, `Sec-Fetch-Site`), and every response from `Network.responseReceived(ExtraInfo)` and redirect responses (status, `Location`, `Referrer-Policy`, CSP, `X-Frame-Options`). The driver never builds an HTTP request itself; its only output is what the browser did. It reads a JSON step list on stdin and writes one `key<TAB>value` line per observation on stdout. A step may also serve a static HTML page on another loopback port (the cross-origin attacker page). |
| R4 | **Frozen integration test** `test/integration/Lockstep/BrowserFormTest.hs`, against real PostgreSQL and the real binary (frozen `Support/Process.withService`), with state asserted in the database (§5). |
| R5 | **Qualification.** The new test runs in `scripts/check --integration` step 6 (no new step). `scripts/a1` replaces its curl form submission with the driver: the UI rename and the duplicate and stale checks through the real form. The A1 log records each browser request's `Origin`/`Referer` and the final URL. |
| R6 | **Demonstration procedure.** Replay is demonstrated with an explicitly reused idempotency key and identical payload (CLI), not with the browser's Back button, which loads a fresh form with a new key. |
| R7 | **Evidence corrections.** Each P1.4–P1.6 record gains a "Correction (2026-10-18)" section stating that its UI-form claims were verified with browser-shaped HTTP requests, not a browser, and that real browser submission failed until R1. Earlier text is kept. Gate A report r1 is kept unchanged as superseded evidence; **r2** is issued against the new tested commit. |

## 2. Allowed paths

`src/Lockstep/Web/Operator.hs` (R1 only); `Dockerfile` (one appended layer, R2);
`test/browser/cdp.py` (new); `test/integration/Lockstep/BrowserFormTest.hs` (new);
`test/integration/Main.hs` (runner, additive); `scripts/a1`; `docs/OPERATOR_GUIDE.md`;
`docs/gates/P1.4/acceptance.md`, `P1.5/acceptance.md`, `P1.6/acceptance.md` (append-only
corrections); `docs/gates/P1.7/**`; `docs/gates/A/**`; `README.md`; `lockstep.cabal`.
No other frozen test may change.

## 3. Production behaviour the tests bind to

R1 headers, observed by the browser. No Haskell API.

## 4. Pre-freeze rule

The candidate test is **run** against the current binary before the freeze. The expected result
is that the real-browser rename, queue and sign-out are refused with 403 (`Origin: null` observed
by the browser): the regression is reproduced. The negative cases must already pass.

## 5. Tests (`BrowserFormTest`)

| Case | Asserts (browser observations and database state) |
|---|---|
| Sign-in in the browser | navigate to the CLI link, press **Sign in** → final URL `/operator`; the POST's `Origin` is exactly `http://127.0.0.1:P`; `lockstep_operator_sessions` has one live session |
| Rename through the served form | `/operator` response has `Referrer-Policy: origin`, CSP `frame-ancestors 'none'`, `X-Frame-Options: DENY`. Type a new name, press **Rename** → POST `Origin` exact, `Referer` exactly `http://127.0.0.1:P/` (origin only), `Sec-Fetch-Site: same-origin`, response 303 to `/operator/receipts/<id>`; final page shows `applied`. Database: workspace name and revision changed; the receipt's actor is `browser-session` |
| Queue through the served form | `/operator/jobs/new` has `Referrer-Policy: origin`. Set 2 steps of 50 ms, press **Queue** → 303 to a receipt; database: one `queued` receipt and a job that reaches `succeeded` |
| Sign-out through the served form | press **Sign out** on `/operator` → POST `Origin` exact, 303 to `/`; database: the session is revoked; then opening `/operator` shows the 401 page |
| Negative: cross-origin page | a page served from another loopback port (another origin, same site, so the browser sends the cookie) auto-presents a form posting a rename with a valid CSRF value to the service. The press is refused with 403; the browser sent that page's `Origin`; the workspace and receipts are unchanged |
| Negative: tampered CSRF | on the real `/operator` page the hidden `csrf` value is changed in the DOM, then **Rename** is pressed → 403; the workspace and receipts are unchanged |
| Negative: no exception for `null` | a page served from another loopback port with `Referrer-Policy: no-referrer` posts the rename form → the browser sends `Origin: null` → 403; unchanged |
| Receipt and center pages | keep `Referrer-Policy: no-referrer` |

## 6. Verification

Fresh-clone `scripts/check --integration` (all six steps, browser tests included); Linux clone;
digests for every frozen file (with C-P1.3 §9.1 and this Contract's §8); runner additive;
licenses unchanged (the shipped binary's closure is unaffected); `scripts/a1` extended; Gate A
report r2.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a new authority, security or
verification conflict. Rollback: revert the R1 commits; the image layer can be dropped.

## 8. Freeze record

Frozen 2026-10-18 by the writing agent (manual; no v2 Supervisor).

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/BrowserFormTest.hs` | `917c7064db3ae1f87e6f223f13d247f467f5da7b527adefbfa79747596cf81f5` |
| `test/browser/cdp.py` (driver, frozen with the test) | `0c85e641c3ab90618729220959e2dd7e8e7ef7d0e1924962651a089632da23c2` |
| `test/integration/Main.hs` (runner, additive: 2 lines) | `d4b7f418784866a7b54b41b468a3ec98bc9d123f14d41a4db1e22b2e8679280d` |
| `Dockerfile` (R2, one appended layer) | `a82933a48e20070de3f123e5082de02c97883f8c2e48d1c685a3a4ca771b10bd` |

Pre-freeze run against the current binary (`r1-evidence/prefreeze-integration-against-current-binary.log`)
reproduced the owner's demonstration failure in the real browser. The browser sent `Origin: null`
for rename, queue and sign-out, each refused with 403. Both pages lacked `Referrer-Policy: origin`.
The cross-origin and `null`-Origin negative cases already passed. The tampered-CSRF case was
refused by the Origin check rather than the CSRF check, as expected before R1. The only other
failure was the amended C-P1.3 assertion (R-P1.3-1), for the same missing header. The remaining
65 tests passed.
