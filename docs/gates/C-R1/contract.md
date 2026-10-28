# Contract — C-R1 Gate C review remediation

- Contract ID: `C-C.R1@v1`
- Status: **FROZEN** (2026-10-27; §4)
- Authority: Planner review disposition of 2026-10-27 (`.local/plans/phase-03_update2.md`, "Reviewer
  dispositions" 1–10 and "Remediation discipline"); the findings in `docs/gates/C/review.md`; the
  contracts they touch: C-P3.5 J2, J5–J8; C-P3.6 K2; C-P3.7 L4; C-P3.8 M3–M6; C-P1.5 (keys).
- Writer: the single writing agent (Implementer, manual).
- Scope: exactly the ten review findings, nothing else. No new capability, no new page, no Phase 4
  work. Earlier frozen tests are not edited; where a disposition cannot be met without editing one,
  that part stops here and goes to the Planner as an exact amendment request (§5).

## 1. What C-R1 delivers

1. A browser decision is serialized per idempotency key from the key lookup to the receipt, under a
   PostgreSQL session-level advisory lock on a connection of its own; an interrupted decision leaves
   a durable marker and is never replayed or given a made-up receipt (findings 1, 5, 6).
2. Connecting a project is serialized per project from the revision check to the last write; a
   failed attempt leaves no Engineer, repository registration or new folder behind (findings 2, 3, 4).
3. Task decisions run under the task lock (C-P3.6 K2 as written) (finding 7).
4. Attribute escaping proved through the renderer and a real browser; a task creation key bound to
   its project; the "nothing chosen" form value no longer shares a spelling with a Profile ID
   (findings 8, 9, 10).

## 2. Decisions

| # | Decision |
|---|---|
| R1 | **Decision lock** (finding 1, option B). `applyDecision` opens one dedicated database connection (its own pool of one, outside the service pool), takes `pg_advisory_lock(7301, hashtext(<key>))` with `lock_timeout = 5s`, and keeps that connection pinned until the end. Under the lock, in order: (1) a receipt with this key: same payload digest → that receipt, replayed; other digest → `key-conflict`; (2) an attempt marker with this key and no receipt: same payload digest → `decision-outcome-uncertain`, other digest → `key-conflict` (either way nothing applied, nothing recorded; amendment A-C.R1-3); (3) one attempt marker row is committed; (4) the operation runs (its own transaction, as before, on the service pool); (5) in one transaction on the lock connection: the lock is proved still held (`pg_locks`, this backend, `advisory`, classid 7301, granted) and the receipt is inserted; a key conflict found there is compared by digest again. The lock is released by `pg_advisory_unlock` and by closing the connection, whatever happens. A lock not granted within 5 s → `decision-busy` (nothing applied, nothing recorded). Any failure of the lock connection or of step 5 returns "unavailable" without a receipt; the marker stays, so the same key can never be replayed into a guessed outcome. Receipts stay insert-only (M4). |
| R2 | **Migration 16** `lockstep_decision_attempts`: `id`, `idempotency_key` unique (C-P1.5 rule), `payload_digest` (64 hex), `subject` uuid, `started_at`; UPDATE, DELETE and TRUNCATE refused by trigger. `lockstep_decision_receipts` gains `ledger_basis text`, NULL for receipts written before migration 16 and for refusals (`CHECK (ledger_basis IS NULL OR outcome = 'applied')`). No existing row changes. |
| R3 | **Expected values in range** (finding 5). `applyDecision` refuses an expected revision or generation outside 0…2³¹−1 with `revision-out-of-range` before any lock, operation or receipt. `decideTask` refuses a Ticket revision outside 0…2³¹−1 the same way. The forms parse `expected`, `ticket_revision` (0…2³¹−1) and the project and task `revision` fields (0…2⁶³−1) as plain decimal digits only; anything else answers "Lockstep could not read this form. Try again." and reaches no operation. |
| R4 | **Receipt freshness** (finding 6). An applied receipt stores the subject's ledger basis the operation produced: `order:<revision>` for stopped work (the Work Order revision after the event), `intent:<state>:<generation>` for an unknown outcome (the intent the operation returned). `DecisionReceipt` gains `receiptCurrent`: the stored basis equals the subject's basis in the current projection. A closed decision's page shows the Done page only for a current receipt; otherwise it says the decision is no longer waiting and was decided or changed elsewhere, with the earlier answer only under *Technical details*. A replayed receipt that is no longer current says so too. A receipt without a basis is never current. |
| R5 | **Project connection lock** (finding 2). `connectProject`, and the folder step of `createProject`, take `pg_advisory_lock(7302, hashtext(<project id>))` on a dedicated connection as in R1 (5 s → `project-busy`, nothing done) and, under it, re-read the project: unknown, `already-connected` and `stale-revision` are answered before any side effect. Then: the folder (an offered one, or a new one made by `git init`), the read-only Git observation(s), and **one** database transaction under the projects lock that re-checks the revision and adds the Engineer, registers the repository (with the existing `origin` fallback) and records the attempt. Refusals inside it keep their C-P2.1 decision rows and are recorded on the project as today. Any database failure rolls the whole transaction back (no Engineer, no registration, no project change), and a folder this attempt made is removed when the attempt does not end connected. |
| R6 | **Folders checked once, and again before mounting** (findings 3, 4; host-user threat model unchanged). `scripts/control-helper`: `folder_refusal` runs once, in the helper's own shell, and sets both the refusal and the canonical path that is written. `scripts/service`: a listed path is mounted only if it is not a symbolic link, is a directory, and its canonical path (`cd -P`, `pwd -P`) is exactly the listed path; otherwise it is skipped like a missing folder. |
| R7 | **Task decisions under the task lock** (finding 7). `decideTask` runs in one transaction: the task lock (`lockTasks`), the task row, the C-P2.2 Ticket decision inside that transaction (`decideTicketIn`, the same rules and refusal rows as `decideTicket`), and the view. A stale Ticket revision is `stale-revision`; any other refusal `not-allowed-now`, as before. C-P3.6 K2's wording is kept. |
| R8 | **Attribute escaping** (finding 8). `Fragment.attr` escapes `"` itself as well (`&quot;`), so no attribute value depends on Brigid's escaping. Proved by a task titled `" autofocus onfocus=alert(1) x="` through the real service and headless Chromium. |
| R9 | **Creation key bound to its project and content** (finding 9). A task creation key already used in another project is refused `key-conflict` and returns nothing of the other project. Since amendment A-C.R1-1 (§5): **migration 17** adds `creation_digest` (64 hex, NULL for earlier rows) to `lockstep_projects` and `lockstep_project_tasks`; it is the SHA-256 of a canonical request text (a project: name, outcome, folder choice; a task: project, title, acceptance, priority, sorted dependencies). The same key replays only when the digest is the same; other content is `key-conflict` and creates nothing. A row without a digest replays only when the request is shown equal to what is stored (a project: the same name and outcome, and *decide later* with no folder or the same existing folder; a task: never edited, and the same title, acceptance, priority and dependencies); anything else, including a new folder, fails closed as `key-conflict`. Words for projects: "This form was already used for another project. Nothing was changed. Open New project again." |
| R10 | **No sentinel** (finding 10). `chooseChecksExpecting` takes `ExpectNothing` or `ExpectProfile id`. The checks form keeps `expected` and adds `expected_set` (`no` when nothing is chosen, `yes` otherwise); with `expected_set` the value of `expected` is taken literally, so a Profile called `none` works. A form without `expected_set` (and the C-P3.7 `chooseChecks` text API) reads `none` as "nothing chosen" only: when a Profile called `none` is the current choice, such a request is refused `checks-changed` (it cannot be told apart, so it fails closed). No Profile ID is restricted. |
| R11 | **Words.** `decision-busy`: "Someone else is answering this right now. Nothing was changed. Try again in a moment."; `decision-outcome-uncertain`: "Lockstep cannot tell whether this answer was recorded. Nothing more was done. Here is how it stands now."; `revision-out-of-range`: the form-error sentence. Projects: `project-busy` "This project is being set up right now. Nothing was changed. Try again in a moment.". Tasks: `key-conflict` "This form was already used for another project. Nothing was changed. Open New task again.". |
| R12 | **Launcher PATH conflict** (dogfood finding 1, product). `lockstep setup-path` and a terminal `./lockstep` launch detect when `lockstep` on `PATH` resolves to another program than Lockstep's link, name that program, say how to run Lockstep (`<checkout>/lockstep`, or `./lockstep` in the checkout), and mention an active virtual environment when one is the cause. Nothing outside `~/.local/bin/lockstep` is created, changed or removed; exit codes are unchanged. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | integration: real PostgreSQL, Git, in-process; two service pools for real concurrency | R1: two concurrent requests with one key and different content → one applied and one `key-conflict`, one receipt, outcome `applied`; with the same content → one applied, one replayed; a key whose lock is held elsewhere → `decision-busy` after the bound, nothing recorded; the lock connection killed while the operation waits → no receipt, the ledger change stands, the same key then `decision-outcome-uncertain` and nothing more; attempt markers immutable; a marker left by another answer with the same key is `key-conflict` (A-C.R1-3). R3: −1 and 2³¹ refused before any receipt. R4: current right after, not current once the work changed elsewhere. R5: two concurrent connects of one project → one Engineer, one registration, one folder; a failure at the Engineer, the registration or the project write → no Engineer, no registration, no new folder, project unchanged. R7: a task decision waits for the task lock; a stale Ticket revision after a title edit is `stale-revision`. R9: a key from another project is `key-conflict`. R10: a Profile called `none`. |
| `test/integration/Lockstep/GateCRemediationPageTest.hs` | integration: real service over HTTP | R3: out-of-range and non-decimal `expected`, `ticket_revision` and `revision` answer the form error and record nothing; R4: a closed decision changed elsewhere shows no Done page; R8: the hostile title escaped in the raw page; R10: `expected_set` on the checks page |
| `test/integration/Lockstep/GateCRemediationFolderTest.hs` | integration: real `scripts/service` with the docker stub (C-P3.5 support), real launcher | R6: a listed symbolic link and a listed path under a symbolic-link parent are not mounted; R12: a `lockstep` earlier on `PATH` is named, the link is still made, the other program is untouched |
| `test/integration/Lockstep/GateCRemediationBrowserTest.hs` | integration: headless Chromium (frozen `test/browser/app_driver.py`), real service | R8: the task page with the hostile title has no `onfocus` or `autofocus` attribute, and the title field holds the exact text |

Not covered by a deterministic test (recorded, not hidden): the helper's check-then-write window in
R6 (a symbolic link re-targeted between the check and the write needs a local race on the owner's
own home folder; the single in-shell check removes the second resolution, and the mount-time check
of R6 is tested).

## 3b. Addendum (2026-10-27): migration 17 and the Review 3 corrections

Authority: the Planner's final authorization (`.local/plans/phase-03_update4.md`): A-C.R1-1's
production change (R9), and Review 3 findings 1, 3 and 4.

| # | Decision |
|---|---|
| R13 | **A connected project's folder is never removed** (Review 3 findings 3, 4). Before removing a folder the attempt made, on the normal failure path and in the exception handler alike, the project is read again from the database; the folder is kept when the project is connected, or records that folder, or its state cannot be read. A folder the attempt did not make is never removed (as before). |
| R14 | **Only synchronous unlock failures are ignored** (Review 3 finding 1). The best-effort `pg_advisory_unlock` after the action ignores synchronous exceptions only; asynchronous ones propagate. For that to reach the caller, `withSessionLock` itself also lets an asynchronous exception propagate instead of turning it into "unavailable" (it destroys the one-connection pool first, so the lock is released); synchronous failures stay "unavailable" as before. This narrows Review 2 INFO 6 for the session lock only; `withDatabase` is unchanged. |
| R15 | **Test fault hook.** `connectProjectWith :: ProjectFaults -> …` runs `faultAfterCommit` once on what the attempt's transaction returned; `connectProject` is `connectProjectWith noProjectFaults`, and nothing in the service, the pages or the CLI can reach another hook. It stands for an interruption after the commit (the hook throws) or a COMMIT whose answer was lost (the hook replaces the result with a database failure); a real lost COMMIT cannot be forced reproducibly in a test. |

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationAddendumTest.hs` | integration: real PostgreSQL, Git, in-process | R13: an interruption after the commit, and a lost COMMIT answer, leave the connected project and its new folder; nothing else in the projects folder is touched; a really failed attempt still removes the folder it made. R9 (migration 17): rows without a creation digest replay only when the request is shown equal; a project's other name or a new folder, a task's other title, or any task after an edit is `key-conflict` |

Not covered by a test: R14 (an asynchronous exception arriving exactly during the unlock cannot be
placed deterministically); it is checked by reading the code.

Pre-freeze baseline (`addendum-prefreeze-baseline.log`, only the amended and new cases, against the
code with the hook and without R9's second half or R13): 6 of 9 fail, each for its finding (A-C.R1-1:
other content returns the first project or task; R13: the connected project's folder is removed in
both cases; migration 17: the column does not exist). The 3 that pass are expected to: the A-C.R1-3
marker case (the code has compared marker digests since `e1c56ef`), the A-C.R1-2 page case (its
fixture is repaired), and "a really failed attempt still removes the folder it made" (R13 must not
keep orphans).

## 3c. Second addendum (2026-10-27): Review 4 of `e1c56ef..d064150`

Review 4 (an agent, read-only; `docs/gates/C/review.md`) found that R13 checked only the attempt's own
project. A folder `git init` has just made is already offered to every other project, so another
project can connect it while the attempt runs; the attempt then removed a folder that project is
connected to. That breaks what the Planner authorized ("preserve the folder if it is connected"), so
it is corrected here under the same authorization, with the dependency-quoting finding (LOW).

| # | Decision |
|---|---|
| R13a | **No project's connected folder is removed.** The re-read and the removal happen in one transaction holding the projects lock: the folder is removed only when the attempt's own project is not connected and does not record it, **and no project is connected to it**; if that cannot be read, it is kept. |
| R13b | **No project is recorded as connected to a missing folder.** Inside the attempt's transaction, under the projects lock and before the Engineer or the registration, the chosen folder must still be a project folder (a real directory with a real `.git`); otherwise the attempt is recorded as failed with `folder-not-offered`. With R13a, either the removal or the connection comes first under the lock, never both. |
| R9a | **Dependencies quoted one by one** in a task's canonical request text, so a dependency that is not a task id cannot join into another list. |
| R15a | **Second test-only hook.** `connectProjectAround` runs a hook once the attempt has its folder and has observed it, right before its transaction (the window of both races). `connectProject` and `connectProjectWith` pass no-op hooks; nothing in the service, pages or CLI reaches it. |

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationFolderRaceTest.hs` | integration: real PostgreSQL, Git, in-process, the R15a hook | R13a: another project connects the folder an attempt made; the attempt fails and the folder stays. R13b: an attempt waits with a folder the other attempt made and then removed; it is not recorded as connected, and no repository is registered. R9a: joined dependency text is not the same request |

Pre-freeze baseline (`addendum2-prefreeze-baseline.log`, only these cases, against the code with
the hook and without R13a, R13b, R9a): **3 of 3 fail**, each for its finding (the connected project's
folder is removed; the second project is recorded as connected to the missing folder; the joined
dependency text replays the other task).

## 3a. Verification record (after implementation)

Implementation: `e49b68e` (on `phase-3`, after the freeze commit `b83db50`), then `e1c56ef` (the
four LOW findings of the independent review of `e49b68e`). The last fully qualified commit is
**`e1c56ef`**; after it, `e679d97` (authorized amendments), `d064150` (migration 17, R13, R14),
`11a035d` (second addendum frozen) and `b9f7d47` (R13a, R13b, R9a) are verified only by the targeted
runs below, **not qualified**.

| Check | Result | Evidence |
|---|---|---|
| Frozen files (C-C.R1 and earlier) | digests unchanged; A-C.R1-2's trial file restored and its digest re-checked | §4, earlier contracts' §4 |
| First run of the C-C.R1 groups against `e49b68e` | 20 of 21 PASSED; the 1 failure is the frozen page case's own fixture (A-C.R1-2) | `first-implementation-integration-run.log` |
| C-C.R1 groups with the proposed A-C.R1-2 diff (trial, not applied) | 21 of 21 PASSED | `trial-with-proposed-a-c.r1-2.log` |
| Mac: `scripts/check --integration` at `e49b68e` (plus uncommitted documents) | format, lint, build, unit 800 of 800, no-live-model guard PASSED; integration **402 of 403**, the 1 failure being the A-C.R1-2 case; backup/restore NOT_RUN (it runs only after a green integration step) | `check-integration-e49b68e.log` |
| Independent read-only review of `7839c21..e49b68e` (an agent, not a human) | no HIGH, no MEDIUM; 4 LOW fixed in `e1c56ef`, 4 INFO kept | `docs/gates/C/review.md`, Review 2 |
| Affected groups after the fixes (C-C.R1, C-P3.8, C-P3.5, launcher) | 77 of 78; the 1 failure is the A-C.R1-2 case | — |
| Mac: `scripts/check --integration` at **`e1c56ef`** (plus uncommitted documents) | format, lint, build, unit 800 of 800, guard PASSED; integration **402 of 403**, the same single A-C.R1-2 case; backup/restore NOT_RUN | `check-integration-e1c56ef.log` |
| Linux clean clone of `e1c56ef` | format, lint, build PASSED; unit 800 of 800; integration **402 of 403**, the same single A-C.R1-2 case; kernel boundary and purity scan clean | `linux-clone.log` |
| Read-only review of the fix delta `e49b68e..e1c56ef` (an agent) | no HIGH, no MEDIUM; 2 LOW, 2 INFO, not yet fixed (owner asked to hold the next qualification); R1 step (2) of this contract trails the code since `e1c56ef` (another digest on a marker is `key-conflict`), proposed amendment A-C.R1-3 | `docs/gates/C/review.md`, Review 3 |

A Linux clean clone of `e49b68e` was started and stopped unfinished when the review fixes
superseded it; its log was overwritten by the `e1c56ef` run.

After the Planner's final authorization (addenda, §3b and §3c), at **`d064150`**, then **`b9f7d47`** (not yet qualified):

| Check | Result | Evidence |
|---|---|---|
| Amendments A-C.R1-1, -2, -3 | original digests checked, exactly the authorized hunks applied to the four test paths, the authorized digests matched (§4; C-P3.5 §4, C-P3.6 §4); applied in `e679d97` | — |
| Addendum suite frozen before R9's second half, R13 and R14 | §4 (`GateCRemediationAddendumTest.hs`, runner) | — |
| Amended and new cases against the code before the implementation (only those cases) | 6 of 9 fail, each for its finding; 3 pass as expected (§3b) | `addendum-prefreeze-baseline.log` |
| Format, lint, pedantic build, unit (800) at `d064150` | PASSED | — |
| C-C.R1 (with the addendum), C-P3.5 and C-P3.6 integration groups at `d064150` (targeted, not a qualification) | **75 of 75 PASSED**, including the A-C.R1-2 case and every case that failed in the baseline | `addendum-implementation-run.log` |
| Read-only code review of `e1c56ef..d064150` (an agent) | 1 MEDIUM (R13 checked only its own project), 1 LOW, 3 INFO; MEDIUM and LOW fixed in the second addendum (§3c) | `docs/gates/C/review.md`, Review 4 |
| Second addendum: its cases against the code before the fix | 3 of 3 fail, each for its finding | `addendum2-prefreeze-baseline.log` |
| Format, lint, pedantic build, unit (800) at `b9f7d47` | PASSED | — |
| C-C.R1 (with both addenda), C-P3.5 and C-P3.6 integration groups at **`b9f7d47`** (targeted, not a qualification) | **78 of 78 PASSED** | `addendum2-implementation-run.log` |
| Read-only check of `d064150..b9f7d47` (an agent) | no HIGH, no MEDIUM; 3 LOW (edge cases of folder identity and the older `git init` cleanup), 1 INFO; **not fixed**, correction plan for the Planner | `docs/gates/C/review.md`, Review 5 |
| Mac `scripts/check --integration` and Linux clean clone of the tip | **NOT_RUN** (owner's stop; one consolidated run to come) | — |

Every earlier frozen case passes on the Mac with the remediation, including the C-P3.5 projects,
C-P3.6 tasks, C-P3.7 checks and C-P3.8 decisions suites whose code changed.

Implementation notes (decisions within the design, recorded here):

- **The lock's lifetime, as built.** `Lockstep.Application.Database.withSessionLock` makes a pool of
  exactly one connection for each locked request (`MaxConnectionsTotal 1`, outside the service
  pool), pins that connection with Orville's `withConnection_`, and gives the body a runner bound to
  that pinned connection. The service pool has one connection per capability (one in the service),
  so work under the lock must not use the lock's connection for its ledger operations, and does
  not: the C-P2.5/C-P2.9 operations keep their own transactions on the service pool, unchanged. The
  lock ends in three independent ways, whichever comes first: `pg_advisory_unlock`, the connection
  being destroyed when anything throws inside the pinned scope, and the pool being destroyed in a
  `finally`. A lost connection cannot be reused: the receipt is written on the lock's own
  connection, inside a transaction that first proves the lock is held by that backend
  (`pg_locks`: advisory, granted, `pid = pg_backend_pid()`, classid 7301, objid `hashtext(key)`,
  objsubid 2). The interruption case of the frozen suite kills that backend while the operation
  waits; the operation then completes on the service pool, no receipt is written, and the same key
  is answered `decision-outcome-uncertain`.
- **Why a marker, not a pending receipt.** The marker table is append-only like the receipts; no row
  is ever updated, so M4's "rows never update" holds. The marker is committed before the operation,
  so a crash, a lost lock connection or an unavailable database after it can never lead to the
  operation being run again under the same key, nor to a receipt that guesses what happened.
  Reloading the decision page gives a fresh key and shows the ledger as it is.
- **Residual window, stated.** Between the marker and the receipt, a crash leaves an applied (or
  refused) operation with a marker and no receipt. The answer to that key is then "cannot tell",
  never a wrong receipt; the C-P3.8 §3a limitation (a wrong `refused` receipt after such a crash)
  is gone.
- **Busy, not unavailable.** A lock wait longer than 5 s (`lock_timeout`, SQLSTATE 55P03) is
  `decision-busy` / `project-busy`: nothing was read or written for the request.
- **Freshness basis.** `order:<revision>` comes from the C-P2.5 receipt of the operation;
  `intent:<state>:<generation>` from the intent the C-P2.9 operation returned. The current basis is
  read with `showWorkOrder` / `loadIntent`. Work put back in line and then claimed again is no
  longer "current" for the old receipt: the closed page then says the decision is no longer waiting
  rather than "Done".
- **Project attempt.** The read-only Git observations (with and without `origin`) run before the
  transaction; the transaction takes the projects lock, checks the revision again, then the Engineer
  (C-P2.1 rows as before), the registration (as before, under the registration lock) and the setup
  row. A `git init` that fails removes the folder it was run in. Lock order inside the transaction
  is projects → repositories, as no other path takes them the other way.
- **Task lock.** `decideTask` takes `lockTasks` (the whole task table, as `createTask` and `editTask`
  already do); C-P3.6 K2 says "a lock on the project's tasks", which the table lock includes.

## 4. Freeze record

Frozen 2026-10-27 by the writing agent (manual), before any of the fixes was implemented.

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | `97b255e2f65d0d7abfbd4a73842baf6b95ea81a902f2e675975b35b4510605fe` (amendment A-C.R1-3; was `8e7beb24a0ef48b86eec4a8368d2f180cf2be105ed63c074a45c88f55e01a9c8`) |
| `test/integration/Lockstep/GateCRemediationPageTest.hs` | `ad05170cefeba7fd9ddf702a3392bd5b6a962c3a3f5c91a233fdbb449bd6806e` (amendment A-C.R1-2; was `4015a2835ae35a6ec3dc018efb31aa0d12e78fc7244203b1cd62a1676c4bd41d`) |
| `test/integration/Lockstep/GateCRemediationFolderTest.hs` | `6497ba92949811893e5e61cdfacba234653a2b4518ebdfc2e84fef141b92e18f` |
| `test/integration/Lockstep/GateCRemediationBrowserTest.hs` | `d95ecee895ef0a1f3ea72effb153799643e6e6f85fcdc054f3f322c45ea652a9` |
| `test/integration/Main.hs` (runner, additive) | `c3450061e7e08a4fa34dcb3f15cacd1427e7ccc58796c37df9101ce027198999` (second addendum; before it `0f7613e8…6193` for the addendum; originally `fd71561c3342b6c788aeeebf4dea9f882b8546f487a0d67068555d1c34f51982`) |
| `test/integration/Lockstep/GateCRemediationAddendumTest.hs` (addendum, §3b) | `16235a713b695f91f196a42379ad08c5aff5ecb54cbafc52ea0c3dd4493451ec` |
| `test/integration/Lockstep/GateCRemediationFolderRaceTest.hs` (second addendum, §3c) | `b5872215d9ff11c12a03eac615386ee9bfdf3aee0736e8f1450a3cf87e6029bb` |

No earlier frozen file is changed; the runner only gains four lines of imports and four groups.

Pre-freeze verification:

- Written before the freeze, with no behaviour: the field `receiptCurrent` (always true) and
  `ExpectedChecks` with a `chooseChecksExpecting` that answers `not-implemented`, so the tests
  compile against the unfixed code.
- Format, lint and the pedantic build pass with the new files (the lint found 3 redundant `<$>`
  hints in the new tests, fixed before the digests were taken).
- The new groups against the unfixed code (`prefreeze-integration-baseline.log`, run with
  `-p C-C.R1` on a disposable PostgreSQL): 19 of 21 fail, each read for its reason, and each is the
  finding itself: the second answer comes back as a replayed receipt instead of `key-conflict`; the
  same answer runs the operation twice (a refusal row); a held key does not make the request wait;
  no lock exists to lose; the marker table does not exist; −1 ends in "unavailable" (the receipt
  insert is refused by its CHECK); the stub's `receiptCurrent`; two Engineers for one project; the
  new folder left after an injected failure (the later two injections are not reached in that run);
  the task decision does not wait for the task lock; an out-of-range Ticket revision is answered
  `stale-revision` and recorded; another project's task comes back; the stub `chooseChecksExpecting`;
  503 for `expected=-1`; the stale-task words instead of the form error; the Done page after the
  work changed elsewhere; no `expected_set` on the checks page; the symbolic links mounted; nothing
  said about the other `lockstep`. The fixtures ran: a halted order, an unknown outcome, two
  pools, held row, table and advisory locks, a project with a real folder and Engineer.
- The 2 that pass before the fix are the R8 escaping cases (page and browser): Brigid already
  escapes `"` in attribute values. They are regression guards for the finding (INFO), as the
  disposition asks ("test … through the actual renderer and browser boundary").
- Found and fixed before the freeze: the first draft of the R8 page case asserted that `" autofocus`
  appears nowhere, but a page heading may show the title's quote characters as text; it now asserts
  that no attribute is broken open (`value="" autofocus`, `x="" maxlength`).

## 5. Stopped here: amendment request A-C.R1-1 (Planner)

Finding 9 asks that "a key reused with different input must conflict". Two frozen tests assert the
opposite for the same project, so this part is **not** implemented: `docs/gates/C-R1/amendment-request-1.md`
holds the exact diffs, provenance and the code change it would authorize.

Status 2026-10-27 (final): A-C.R1-1, A-C.R1-2 and A-C.R1-3 were given **final authorization** by
the Planner (`.local/plans/phase-03_update4.md`) and applied: each original digest was checked
before the edit, exactly the authorized hunks were applied to the intended test paths (not the
`.local` copies the patch headers name), and each result matches the authorized digest (§4;
C-P3.5 §4, C-P3.6 §4). R1 step (2), R9 and the §3 row were amended as authorized. R9's second half is
implemented with migration 17 (§3b).
