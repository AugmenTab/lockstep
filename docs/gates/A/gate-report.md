# Gate A report — Phase 1: Application shell and durable operator command

- Report revision: **r1** (2026-10-18). The owner's decision binds to this file's SHA-256, which
  `decision-packet.md` records (VISUAL_EVIDENCE_CONTRACT §7).
- Repository: `AugmenTab/lockstep` (private), branch `v2`
- **Tested commit: `de8afa310e13a8d2b699ac4627afe092393b087a`**, clean. A1 ran from this
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

**Machine summary: `NOT_RUN`** (worst required row). Every agent-executable criterion is
`PASSED`; the required human-operated demonstration (AC-A1-18) has not been performed. **This
summary is not acceptance. Gate A is decided only by the human owner.**

## 1. A1 criteria

Evidence: `docs/gates/A/evidence/a1/` (run `20261018T182651Z`; `a1.log` records every command with argv,
exit code and output digests; `SHA256SUMS` covers every file). Method for rows 01–17: scenario
`scripts/a1` against the installed service (container `lockstep-a1`, `127.0.0.1:8100`), with a
fresh database ``lockstep_a1_20261018t182651z`` on the operator PostgreSQL server.

| Criterion | Statement | Source refs | Req. | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|---|---|
| `AC-A1-01@v1` | Clean build and full verification from a fresh clone | FR-APP-01, NFR-07/09/13 | yes | `scripts/check --integration` exits 0; all six steps PASSED, step 5 included | format, lint, build, 259 unit, guard (5/5 + self-test), 66 integration + backup/restore: all PASSED | PASSED | `a1/check-fresh-clone.log` ``fc7735e2…`` |
| `AC-A1-02@v1` | The installed binary is built from a clean checkout of the tested commit | NFR-11 | yes | `.local/install/VERSION`: tested commit, `dirty false` | as expected (`a1/VERSION`) | PASSED | `a1/VERSION` ``5dec58a3…`` |
| `AC-A1-03@v1` | Real PostgreSQL migration and readiness | FR-APP-03 | yes | fresh DB → `db migrate` applies 1–5 → `readiness ready 5` | as expected | PASSED | `a1/a1.log` § A1-03 |
| `AC-A1-04@v1` | The installed service answers on loopback | FR-APP-01/05 | yes | health 204; readiness `200 ready 5` on `127.0.0.1:8100` | as expected | PASSED | § A1-04 |
| `AC-A1-05@v1` | No non-loopback exposure on the host | FR-APP-05, NFR-04 | yes | every listener on the port is `127.0.0.1`/`::1`; the Mac's LAN address refuses | `lsof`: one listener `127.0.0.1:8100` (OrbStack); LAN address refused (curl exit 7) | PASSED | § A1-04b |
| `AC-A1-06@v1` | Explicit operator sign-in | FR-APP-05 | yes | CLI one-time link; confirm page 200; exchange 303 → `/operator` with a session cookie | as expected | PASSED | § A1-05 |
| `AC-A1-07@v1` | Typed command through the UI; duplicate returns the same receipt | FR-APP-04, NFR-01/02 | yes | 303 to a receipt; the same form again → same `Location` | as expected (`/operator/receipts/1` twice) | PASSED | § A1-06 |
| `AC-A1-08@v1` | Operator pages cannot be framed | FR-APP-05 | yes | `X-Frame-Options: DENY`; `Content-Security-Policy: frame-ancestors 'none'` | as expected | PASSED | § A1-06b |
| `AC-A1-09@v1` | Typed command through the CLI is the same operation | FR-APP-04 | yes | applied at revision 2; the duplicate prints the same receipt, `(replayed)` | as expected | PASSED | § A1-07 |
| `AC-A1-10@v1` | Stale commands are refused durably | FR-APP-04 | yes | CLI exit 65 with a `refused_stale` receipt; form 409 | as expected | PASSED | § A1-08 |
| `AC-A1-11@v1` | Unauthorized requests are refused and store nothing | FR-APP-05, NFR-04 | yes | no session 401; wrong CSRF 403; foreign Origin 403; `Host: localhost` 403; receipt count unchanged | as expected | PASSED | § A1-09 |
| `AC-A1-12@v1` | Closing the client does not abandon accepted work | FR-APP-04, NFR-08 | yes | a client that disconnects right after queueing → the job succeeds | `job 1 succeeded steps 5/5 attempts 1` | PASSED | § A1-10 |
| `AC-A1-13@v1` | After a service restart the same operation and evidence are shown | FR-APP-02/04/09, NFR-08/14 | yes | receipt shows `applied`; command center shows the job `PASSED`; counts match the database | as expected | PASSED | § A1-11; `a1/center-after-restart.html` |
| `AC-A1-14@v1` | Durable receipts in PostgreSQL | FR-APP-04, NFR-02 | yes | 2 applied, 2 refused_stale, 1 queued; the job has an outcome digest | as expected (`a1/receipts.txt`, `a1/jobs.txt`) | PASSED | § A1-12 |
| `AC-A1-15@v1` | User-supplied text cannot inject markup | FR-APP-05 | yes | the name `<b>"&x</b>` renders entity-escaped; no attribute breakout | as expected | PASSED | § A1-12b |
| `AC-A1-16@v1` | Rendered pages captured and inspected | NFR-12/14 | yes | labelled screenshots of the command center and a receipt after restart | captured; inspected (`PROVENANCE`) | PASSED | `a1/center-after-restart.png` ``20ecde3c…`` |
| `AC-A1-17@v1` | Zero live-model calls | NFR-09/13, TESTING_STRATEGY §8 | yes | `claude` resolves to the shim inside the service container; a canary call is logged (exit 97); the service's sentinel log is empty; no password, token or session value in the recorded output | as expected | PASSED | § A1-14 |
| `AC-A1-18@v1` | **Human-operated demonstration** in the owner's own browser (TESTING_STRATEGY §2.1) | PRD A1; TESTING_STRATEGY §2.1 | yes | the owner completes §4 and records the result | **not performed** | **NOT_RUN** | — (blocker: the owner) |
| `AC-A1-19@v1` | Same suite on a case-sensitive Linux filesystem | NFR-07 | yes | format, lint, build, unit, integration PASSED in a clone inside the dev container | all five PASSED (259 unit, 66 integration) | PASSED | `docs/gates/P1.7/evidence/check-linux-clone.log` |
| `AC-A1-20@v1` | Frozen tests intact; only the authorized amendment after a freeze | process (handoff rules 4–5) | yes | all frozen digests OK; runner diffs additive; only R-P1.5-1 changed a frozen file | 37/37 OK; runners +22/+10, 0 removed; R-P1.5-1 byte-identical | PASSED | `docs/gates/P1.7/evidence/sha-and-diff-checks.log` |
| `AC-A1-21@v1` | License policy | ARCHITECTURE §5.2, ADR-0003 | yes | no unapproved linked license; inventory unchanged since P1.2 | `license policy: no unapproved linked license`; byte-identical to the P1.6 (and P1.2) inventory | PASSED | `docs/gates/P1.7/evidence/licenses.txt` |
| `AC-A1-22@v1` | Independent read-only review | handoff §P1.7 | yes | review of the actual diffs recorded with dispositions | done (agent reviewer, not human): no HIGH; 4 MEDIUM (3 fixed, 1 for the owner) | PASSED | `docs/gates/A/review.md` |

## 2. Sub-phase status

| Sub-phase | Status | Tested commit | Record |
|---|---|---|---|
| P1.1 Minimal Launchpad-derived app | **ACCEPTED** by the owner | `b3a3723` | `docs/gates/P1.1/acceptance.md` |
| P1.2 PostgreSQL, migrations, readiness | **ACCEPTED** by the owner | `b3a3723` | `docs/gates/P1.2/acceptance.md`, `r1-acceptance-packet.md` |
| P1.3 Operator trust and request security | VERIFIED — awaiting the owner | `d2f04ea` | `docs/gates/P1.3/acceptance.md` |
| P1.4 Typed durable operator command | VERIFIED — awaiting the owner | `75cc862` | `docs/gates/P1.4/acceptance.md` |
| P1.5 Background dispatcher | VERIFIED — awaiting the owner | `10a849d` | `docs/gates/P1.5/acceptance.md` |
| P1.6 Command center and evidence UI | VERIFIED — awaiting the owner | `2ac0059` | `docs/gates/P1.6/acceptance.md` |
| P1.7 Qualification and Gate A | VERIFIED — awaiting the owner | `de8afa3` | `docs/gates/P1.7/acceptance.md` |

Code changed after P1.3–P1.6 were verified, in P1.7 fixes from the review and A1. The tested
commit above covers all of it: A1 and the full suite ran at `de8afa3`. Those post-verification
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

## 4. Human-operated demonstration (AC-A1-18; the owner performs it)

About 10 minutes, in your own browser, against the installed service. Nothing here is done by the
agent; this row stays NOT_RUN until you record the result.

1. `git status` is clean at the tested commit; `scripts/db up`; `scripts/service install`
   (`.local/install/VERSION` shows the tested commit and `dirty false`); `scripts/service start`.
2. Open `http://127.0.0.1:8000/`: the status page says the database is ready at revision 5.
3. `scripts/service cli operator sign-in`, open the printed link, press **Sign in**. You land on
   `/operator`.
4. Rename the workspace with the form. You land on a receipt page showing `applied`. Press the
   browser's Back button and submit the same form again: you get the **same** receipt number.
5. In a terminal, run a stale command:
   `scripts/service cli workspace rename --expected-revision 0 "Too old"` → exit 65 and a
   `refused_stale` receipt.
6. Open `/operator/jobs/new`, queue a job with 10 steps of 1000 ms, then **close the browser tab**
   straight away.
7. `scripts/service restart`. Open a new tab at `http://127.0.0.1:8000/operator/center`
   (sign in again if asked).
8. Check: the job finishes (refresh until it shows `PASSED`); the status table shows the counts
   with their meanings; the stale command is listed as `refused_stale`; nothing that is not
   finished or not verified is green.
9. Optional: open `http://localhost:8000/` (refused, 403).
10. Record the result in `decision-packet.md` (what you saw, date, anything unexpected).

No model is invoked at any point.

## 5. Decision (owner only)

| Field | Value |
|---|---|
| Gate A | *(ACCEPTED / REJECTED / DEFERRED — owner)* |
| Report revision and SHA-256 | r1, `<recorded in decision-packet.md>` |
| Sub-phases P1.3–P1.7 | *(owner)* |
| Session-cookie limitation (§3.1) | *(owner: option a / b / c)* |
| Human demonstration result | *(owner)* |
| Decided by / at | *(owner)* |
