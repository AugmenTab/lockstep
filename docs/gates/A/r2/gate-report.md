# Gate A report — Phase 1: Application shell and durable operator command

- Report revision: **r2** (2026-10-18). The owner's decision binds to this file's SHA-256, which
  `docs/gates/A/r2/decision-packet.md` records (VISUAL_EVIDENCE_CONTRACT §7).
- **Supersedes r1** (`docs/gates/A/gate-report.md`, sha256 `efee1118…`, kept unchanged). r1 is
  evidence of the **failed human demonstration**. In the owner's browser, the operator forms were
  refused: the pages sent `Referrer-Policy: no-referrer`, so the browser sent `Origin: null`. r1's
  AC-A1-07 had been verified with browser-shaped HTTP requests, not a browser. Report, decisions
  and remediation: `docs/gates/A/r2/browser-forms-regression.md`; Contract C-P1.7-R1.
- Repository: `AugmenTab/lockstep` (private), branch `v2`
- **Tested commit: `6c2851d40a13be9ce08c97e692e30575b7b7d6e2`**, clean. A1 ran from this
  checkout and from a fresh clone of it.
- Schema revision: **5** (migrations 0001–0005)
- Policy identity: `manual — no v2 Supervisor`
- Governing documents (digests verified against `docs/governance/SOURCE_REGISTER.md` on
  2026-10-18): Bible v2.1 `62196658…640ff`; PRD v0.2 `bbd407fd…17dfe`; Plan v0.2 `ae85b482…e6345`;
  Phase 1 handoff `.local/plans/phase-01.md` `a4f6a5bb…48b4`; VISUAL_EVIDENCE_CONTRACT
  `630a93f4…9bbf`; TESTING_STRATEGY `3f0f7e23…81cb7`; ARCHITECTURE `e2d49b62…da88`.
- Environment: macOS arm64; Docker Engine 29.4.0 via **OrbStack**; dev image `lockstep-dev:p1`
  (GHC 9.10.3, Stack); PostgreSQL `postgres:17.11-bookworm@sha256:3645570c…3826`; Chromium 155.
- Executed by: manual agent session (writing agent / Implementer), 2026-10-18. Adapter kind:
  scripted; no live model was invoked.

**Machine summary: `NOT_RUN`** (worst required row). Every agent-executable criterion (22 of 23) is
`PASSED`; the required human-operated demonstration (AC-A1-18) has not been performed. **This
summary is not acceptance. Gate A is decided only by the human owner.**

## 1. A1 criteria

Evidence: `docs/gates/A/r2/evidence/a1/` (run `20261018T193229Z`; `a1.log` records every command with argv,
exit code and output digests; `SHA256SUMS` covers every file). Method for rows 01–17 and 23: scenario
`scripts/a1` against the installed service (container `lockstep-a1`, `127.0.0.1:8100`), with a
fresh database `lockstep_a1_20261018t193229z` on the operator PostgreSQL server.

| Criterion | Statement | Source refs | Req. | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|---|---|
| `AC-A1-01@v1` | Clean build and full verification from a fresh clone | FR-APP-01, NFR-07/09/13 | yes | `scripts/check --integration` exits 0; all six steps PASSED, step 5 included | format, lint, build, 259 unit, guard (5/5 + self-test), 67 integration (the real-browser test included) + backup/restore: all PASSED | PASSED | `a1/check-fresh-clone.log` ``f48f3bfe…`` |
| `AC-A1-02@v1` | The installed binary is built from a clean checkout of the tested commit | NFR-11 | yes | `.local/install/VERSION`: tested commit, `dirty false` | as expected (`a1/VERSION`) | PASSED | `a1/VERSION` ``5c759b9f…`` |
| `AC-A1-03@v1` | Real PostgreSQL migration and readiness | FR-APP-03 | yes | fresh DB → `db migrate` applies 1–5 → `readiness ready 5` | as expected | PASSED | `a1/a1.log` § A1-03 |
| `AC-A1-04@v1` | The installed service answers on loopback | FR-APP-01/05 | yes | health 204; readiness `200 ready 5` on `127.0.0.1:8100` | as expected | PASSED | § A1-04 |
| `AC-A1-05@v1` | No non-loopback exposure on the host | FR-APP-05, NFR-04 | yes | every listener on the port is `127.0.0.1`/`::1`; the Mac's LAN address refuses | `lsof`: one listener `127.0.0.1:8100` (OrbStack); LAN address refused (curl exit 7) | PASSED | § A1-04b |
| `AC-A1-06@v1` | Explicit operator sign-in | FR-APP-05 | yes | CLI one-time link; confirm page 200; exchange 303 → `/operator` with a session cookie | as expected | PASSED | § A1-05 |
| `AC-A1-07@v2` | A typed command through the served UI form **in a real browser** | FR-APP-02/04/05 | yes | headless Chromium signs in, types a new name into the served `/operator` form and presses **Rename**: the POST carries the exact `Origin` and an origin-only `Referer`; 303 to an `applied` receipt; the database shows the rename attributed to `browser-session`; the form's **Sign out** works | as expected (`rename.post.origin http://127.0.0.1:8100`, `referer …/`, 303; receipt actor `browser-session`) | PASSED | § A1-06, A1-06c |
| `AC-A1-08@v1` | Operator pages cannot be framed | FR-APP-05 | yes | `X-Frame-Options: DENY`; `Content-Security-Policy: frame-ancestors 'none'` | as expected | PASSED | § A1-06b |
| `AC-A1-09@v1` | Typed command through the CLI is the same operation; replay with an explicitly reused key and identical payload returns the same receipt | FR-APP-04 | yes | applied at revision 2; the duplicate prints the same receipt, `(replayed)` | as expected | PASSED | § A1-07 |
| `AC-A1-10@v1` | Stale commands are refused durably | FR-APP-04 | yes | CLI exit 65 with a `refused_stale` receipt; form 409 | as expected | PASSED | § A1-08 |
| `AC-A1-11@v1` | Unauthorized requests are refused and store nothing | FR-APP-05, NFR-04 | yes | no session 401; wrong CSRF 403; foreign Origin 403; `Host: localhost` 403; receipt count unchanged | as expected | PASSED | § A1-09 |
| `AC-A1-12@v1` | Closing the client does not abandon accepted work | FR-APP-04, NFR-08 | yes | a client that disconnects right after queueing → the job succeeds | `job 1 succeeded steps 5/5 attempts 1` | PASSED | § A1-10 |
| `AC-A1-13@v1` | After a service restart the same operation and evidence are shown | FR-APP-02/04/09, NFR-08/14 | yes | receipt shows `applied`; command center shows the job `PASSED`; counts match the database | as expected | PASSED | § A1-11; `a1/center-after-restart.html` |
| `AC-A1-14@v1` | Durable receipts in PostgreSQL | FR-APP-04, NFR-02 | yes | 2 applied, 2 refused_stale, 1 queued; the job has an outcome digest | as expected (`a1/receipts.txt`, `a1/jobs.txt`) | PASSED | § A1-12 |
| `AC-A1-15@v1` | User-supplied text cannot inject markup | FR-APP-05 | yes | the name `<b>"&x</b>` renders entity-escaped; no attribute breakout | as expected | PASSED | § A1-12b |
| `AC-A1-16@v1` | Rendered pages captured and inspected | NFR-12/14 | yes | labelled screenshots of the command center and a receipt after restart | captured; inspected (`PROVENANCE`) | PASSED | `a1/center-after-restart.png` ``07845ce1…`` |
| `AC-A1-17@v1` | Zero live-model calls | NFR-09/13, TESTING_STRATEGY §8 | yes | `claude` resolves to the shim inside the service container; a canary call is logged (exit 97); the service's sentinel log is empty; no password, token or session value in the recorded output | as expected | PASSED | § A1-14 |
| `AC-A1-18@v2` | **Human-operated demonstration** in the owner's own browser (TESTING_STRATEGY §2.1). v1 **FAILED** on r1 at step 4; v2 has the corrected procedure | PRD A1; TESTING_STRATEGY §2.1 | yes | the owner completes §4 and records the result | **not performed** | **NOT_RUN** | — (blocker: the owner) |
| `AC-A1-19@v1` | Same suite on a case-sensitive Linux filesystem | NFR-07 | yes | format, lint, build, unit, integration PASSED in a clone inside the dev container | all five PASSED (259 unit, 67 integration, the real-browser test included) | PASSED | `docs/gates/P1.7/r1-evidence/check-linux-clone.log` |
| `AC-A1-20@v2` | Frozen tests intact; only authorized amendments after a freeze | process (handoff rules 4–5) | yes | all frozen digests OK; runners additive; only R-P1.5-1 and R-P1.3-1 changed frozen files, each byte-identical to its authorized diff | 39/39 OK; runners 0 removed lines; R-P1.3-1 byte-identical | PASSED | `docs/gates/P1.7/r1-evidence/sha-and-diff-checks.log` |
| `AC-A1-21@v1` | License policy | ARCHITECTURE §5.2, ADR-0003 | yes | no unapproved linked license; inventory unchanged | byte-identical to the earlier inventories (the image's Chromium and Python are not in the binary's closure) | PASSED | `docs/gates/P1.7/r1-evidence/licenses.txt` |
| `AC-A1-22@v2` | Independent read-only review | handoff §P1.7 | yes | review of the actual diffs recorded with dispositions | done twice (agent reviewer, not human). Through `95ca7c2`: no HIGH; 4 MEDIUM (3 fixed, 1 for the owner). Remediation `de8afa3..6c2851d`: no HIGH; 1 MEDIUM (R5 partly met: the browser stale check moves to the human demonstration; the form duplicate is impossible by design) | PASSED | `docs/gates/A/review.md`; `docs/gates/A/r2/review-remediation.md` |
| `AC-A1-23@v1` | **Real-browser regression test** in the qualification suite (C-P1.7-R1 §5) | FR-APP-02/05; Planner decision | yes | frozen `BrowserFormTest`: Chromium submits the served rename, queue and sign-out forms (state checked in PostgreSQL); cross-origin, `null`-Origin and tampered-CSRF submissions refused and store nothing | passes in the fresh clone (step 6) and the Linux clone; reproduced the demonstration failure before the fix | PASSED | `a1/check-fresh-clone.log`; `docs/gates/P1.7/r1-evidence/prefreeze-integration-against-current-binary.log` |

## 2. Sub-phase status

| Sub-phase | Status | Tested commit | Record |
|---|---|---|---|
| P1.1 Minimal Launchpad-derived app | **ACCEPTED** by the owner | `b3a3723` | `docs/gates/P1.1/acceptance.md` |
| P1.2 PostgreSQL, migrations, readiness | **ACCEPTED** by the owner | `b3a3723` | `docs/gates/P1.2/acceptance.md`, `r1-acceptance-packet.md` |
| P1.3 Operator trust and request security | VERIFIED — awaiting the owner | `d2f04ea` | `docs/gates/P1.3/acceptance.md` |
| P1.4 Typed durable operator command | VERIFIED — awaiting the owner | `75cc862` | `docs/gates/P1.4/acceptance.md` |
| P1.5 Background dispatcher | VERIFIED — awaiting the owner | `10a849d` | `docs/gates/P1.5/acceptance.md` |
| P1.6 Command center and evidence UI | VERIFIED — awaiting the owner | `2ac0059` | `docs/gates/P1.6/acceptance.md` |
| P1.7 Qualification and Gate A | VERIFIED — awaiting the owner; remediated under C-P1.7-R1 | `6c2851d` | `docs/gates/P1.7/acceptance.md`, `r1-acceptance.md` |

Code changed after P1.3–P1.6 were verified, in P1.7 fixes from the review and A1, and in the C-P1.7-R1 remediation (`Referrer-Policy: origin` on `/operator` and `/operator/jobs/new`; corrections appended to the P1.4–P1.6 records). The tested
commit above covers all of it: A1 and the full suite ran at `6c2851d`. Those post-verification
changes are: framing headers, sign-out failure handling, attribute escaping
(`Web/Operator.hs`); receipt-insert abort (`Application/Command.hs`); dispatcher logging and
supervision (`Application/Dispatcher.hs`); SIGTERM ordering (`Web/Server.hs`, in P1.5).

## 3. Known issues and limitations

1. **Session cookie is shared with every service on 127.0.0.1 (review finding 1; owner
   decision).** Browsers scope cookies by host, not port. Any other HTTP service on
   `127.0.0.1` that the operator's browser visits within 12 hours receives `lockstep_session`.
   A local process that captures it has operator authority: it can send the exact Host/Origin
   itself and derive the CSRF value. A page on another 127.0.0.1 port can also plant a second
   cookie and force 401s (finding 12). The approved design (C-P1.3 E4 `Path=/`; D-1a exact
   `127.0.0.1:<port>`) does not address this. Options for the owner:
   (a) accept for Phase 1 (single operator, single trusted machine);
   (b) `Path=/operator` and a shorter `Max-Age` (reduces casual exposure only);
   (c) a dedicated loopback hostname (for example a `/etc/hosts` name), which changes D-1a.
2. **Brigid 0.4 does not escape `value` attributes** (found by A1 run 2). Worked around in
   Lockstep; any future use of `A.value` with untrusted text must use the escaping helper.
   Worth reporting upstream.
3. **No frozen test covers** the framing headers, the attribute escaping, or the outcome
   digest's error branch. They are checked by A1 (rows 08, 15) or not at all (digest error
   branch, finding 9).
4. **Job evidence model limits (C-P1.6):** PASSED comes from `state = 'succeeded'`; rule 4
   (stale revision) cannot fire for job rows; the digest covers the displayed row, so a full row
   rewrite is not detected.
5. **Dispatcher:** no attempt limit (jobs are model-free no-ops). Starts only if the database
   is ready when `serve` starts (documented). Claim/lease/resume are provisional for the no-op
   kind and **do not decide DG-04** (owner's A2 wording).
6. **Test helper connection churn** (C-P1.5 §9.2): the frozen P1.2 `Support/Postgres` helper
   opens a pool per query. Recorded, not fixed (owner's instruction).
7. **Host access depends on the Docker runtime:** loopback-only forwarding was measured on
   OrbStack. Re-run `scripts/a1` after changing the runtime.
8. **TESTING_STRATEGY §8.2 PATH wording:** the test PATH is the shim directory plus the dev
   image's PATH (system and toolchain directories), not a hand-built list (review finding 4,
   residual).
9. **A1 screenshots** need Chromium downloaded at run time (not reproducible offline). The
   service and A1 scripts assume the compact JSON config that `scripts/db` writes.
10. **Pre-distribution items unchanged:** ADR-0003 LGPL exception; dynamic LGPL system
    libraries via libpq; GMP.

11. **Browser tests need the dev image's Chromium and Python** (one appended `Dockerfile` layer,
    test tooling only). They drive Chromium 155 over the DevTools protocol. Firefox and Safari are
    not exercised by the suite; the D-2d probe covered Firefox ESR for the referrer behaviour.
12. **No automated real-browser stale check.** It needs the browser paused while the revision
    changes, which would mean extending the frozen driver. The server's stale refusal is covered
    at HTTP level (A1-08), and the owner checks it in the browser (§4 step 5b). A duplicate
    through the form is impossible by design: Back loads a fresh key.
13. **The service runs in the dev image**, which now also contains Chromium and Python. The
    installed binary links neither (`docs/gates/P1.7/r1-evidence/ldd-installed-binary.txt`). A
    slim runtime image is a follow-up.
14. **HTTP-level checks** (A1-08 stale form, A1-09 refusals, A1-10 disconnect) still use
    browser-shaped requests and are labelled as server behaviour. The browser-specific claims are
    carried by AC-A1-07@v2 and AC-A1-23.

## 4. Human-operated demonstration (AC-A1-18@v2; the owner performs it)

About 10 minutes, in your own browser, against the installed service. The agent does none of it;
this row stays NOT_RUN until you record the result. Corrected from r1: replay is shown with an
explicitly reused key, because Back loads a fresh form with a new key.

Port 8000 is used by another project's container on this machine (`carillon-api-1`), so these
steps use **8010**. Any free port works if you use it consistently.

1. **Start.** Run `git status` (clean at the tested commit) and `scripts/db up`. `cat
   .local/install/VERSION` must show the tested commit and `dirty false`; if it doesn't, run
   `scripts/service install`. Then `scripts/service start --port 8010`.
2. **Status page.** Open `http://127.0.0.1:8010/`: the database is ready at revision 5.
3. **Sign in.** Run `scripts/service cli operator sign-in --port 8010`, open the printed link and
   press **Sign in**. You land on `/operator`.
4. **Rename through the browser form.** Rename the workspace with the form on `/operator`. You
   land on a receipt page showing `applied`. (This is the step that failed in r1.)
5. **Replay with a reused key, and a stale command (terminal).** Use the revision shown on
   `/operator` as N:
   `scripts/service cli workspace rename --expected-revision N --idempotency-key demo-key-0000000001 "Demo"`,
   then the identical command again. The second prints the same receipt with `(replayed)`.
   Then `scripts/service cli workspace rename --expected-revision 0 "Too old"`: exit 65 and a
   `refused_stale` receipt.

   **5b. Stale through the browser.** Open `/operator` in two tabs. Rename in tab A. Then, in tab
   B (still showing the old revision), submit its rename form: you get a 409 page showing a
   `refused_stale` receipt. This is the real-browser stale check that the automated suite does
   not cover (review of the remediation, finding 1).
6. **Queue a job, then close the tab.** Open `http://127.0.0.1:8010/operator/jobs/new`, queue 10
   steps of 1000 ms, then close the tab straight away.
7. **Restart.** `scripts/service restart --port 8010`.
8. **Command center.** Open a new tab at `http://127.0.0.1:8010/operator/center`. Refresh until
   your job shows `PASSED` (it can take about 2 minutes if an older queued job runs first).
   Check that:
   - each status row reads as label, count and meaning together;
   - your stale command is listed as `refused_stale`;
   - nothing unfinished or unverified is green. Jobs that finished before outcome digests existed
     show `INCONCLUSIVE (incomplete evidence)`, and the earlier deterministic failure shows
     `FAILED`, so the summary is `FAILED`. That is expected.
9. **Sign out with the button** on `/operator`. You land on `/`; opening `/operator` again shows
   "Not signed in".
10. **Optional refusal.** Open `http://localhost:8010/`: refused (403).
11. **Stop and record.** `scripts/service stop`, then record what you saw in `decision-packet.md`
    (date, each check, anything unexpected).

No model is invoked at any point.

## 5. Decision (owner only)

| Field | Value |
|---|---|
| Gate A | *(ACCEPTED / REJECTED / DEFERRED — owner)* |
| Report revision and SHA-256 | r2, `<recorded in r2/decision-packet.md>` |
| Sub-phases P1.3–P1.7 | *(owner)* |
| Session-cookie limitation (§3.1) | *(owner: option a / b / c)* |
| Human demonstration result | *(owner)* |
| Decided by / at | *(owner)* |
