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
| R1 | **Decision lock** (finding 1, option B). `applyDecision` opens one dedicated database connection (its own pool of one, outside the service pool), takes `pg_advisory_lock(7301, hashtext(<key>))` with `lock_timeout = 5s`, and keeps that connection pinned until the end. Under the lock, in order: (1) a receipt with this key: same payload digest → that receipt, replayed; other digest → `key-conflict`; (2) an attempt marker with this key and no receipt → `decision-outcome-uncertain` (nothing applied, nothing recorded); (3) one attempt marker row is committed; (4) the operation runs (its own transaction, as before, on the service pool); (5) in one transaction on the lock connection: the lock is proved still held (`pg_locks`, this backend, `advisory`, classid 7301, granted) and the receipt is inserted; a key conflict found there is compared by digest again. The lock is released by `pg_advisory_unlock` and by closing the connection, whatever happens. A lock not granted within 5 s → `decision-busy` (nothing applied, nothing recorded). Any failure of the lock connection or of step 5 returns "unavailable" without a receipt; the marker stays, so the same key can never be replayed into a guessed outcome. Receipts stay insert-only (M4). |
| R2 | **Migration 16** `lockstep_decision_attempts`: `id`, `idempotency_key` unique (C-P1.5 rule), `payload_digest` (64 hex), `subject` uuid, `started_at`; UPDATE, DELETE and TRUNCATE refused by trigger. `lockstep_decision_receipts` gains `ledger_basis text`, NULL for receipts written before migration 16 and for refusals (`CHECK (ledger_basis IS NULL OR outcome = 'applied')`). No existing row changes. |
| R3 | **Expected values in range** (finding 5). `applyDecision` refuses an expected revision or generation outside 0…2³¹−1 with `revision-out-of-range` before any lock, operation or receipt. `decideTask` refuses a Ticket revision outside 0…2³¹−1 the same way. The forms parse `expected`, `ticket_revision` (0…2³¹−1) and the project and task `revision` fields (0…2⁶³−1) as plain decimal digits only; anything else answers "Lockstep could not read this form. Try again." and reaches no operation. |
| R4 | **Receipt freshness** (finding 6). An applied receipt stores the subject's ledger basis the operation produced: `order:<revision>` for stopped work (the Work Order revision after the event), `intent:<state>:<generation>` for an unknown outcome (the intent the operation returned). `DecisionReceipt` gains `receiptCurrent`: the stored basis equals the subject's basis in the current projection. A closed decision's page shows the Done page only for a current receipt; otherwise it says the decision is no longer waiting and was decided or changed elsewhere, with the earlier answer only under *Technical details*. A replayed receipt that is no longer current says so too. A receipt without a basis is never current. |
| R5 | **Project connection lock** (finding 2). `connectProject`, and the folder step of `createProject`, take `pg_advisory_lock(7302, hashtext(<project id>))` on a dedicated connection as in R1 (5 s → `project-busy`, nothing done) and, under it, re-read the project: unknown, `already-connected` and `stale-revision` are answered before any side effect. Then: the folder (an offered one, or a new one made by `git init`), the read-only Git observation(s), and **one** database transaction under the projects lock that re-checks the revision and adds the Engineer, registers the repository (with the existing `origin` fallback) and records the attempt. Refusals inside it keep their C-P2.1 decision rows and are recorded on the project as today. Any database failure rolls the whole transaction back (no Engineer, no registration, no project change), and a folder this attempt made is removed when the attempt does not end connected. |
| R6 | **Folders checked once, and again before mounting** (findings 3, 4; host-user threat model unchanged). `scripts/control-helper`: `folder_refusal` runs once, in the helper's own shell, and sets both the refusal and the canonical path that is written. `scripts/service`: a listed path is mounted only if it is not a symbolic link, is a directory, and its canonical path (`cd -P`, `pwd -P`) is exactly the listed path; otherwise it is skipped like a missing folder. |
| R7 | **Task decisions under the task lock** (finding 7). `decideTask` runs in one transaction: the task lock (`lockTasks`), the task row, the C-P2.2 Ticket decision inside that transaction (`decideTicketIn`, the same rules and refusal rows as `decideTicket`), and the view. A stale Ticket revision is `stale-revision`; any other refusal `not-allowed-now`, as before. C-P3.6 K2's wording is kept. |
| R8 | **Attribute escaping** (finding 8). `Fragment.attr` escapes `"` itself as well (`&quot;`), so no attribute value depends on Brigid's escaping. Proved by a task titled `" autofocus onfocus=alert(1) x="` through the real service and headless Chromium. |
| R9 | **Creation key bound to its project** (finding 9, first part). A task creation key already used in another project is refused `key-conflict` and returns nothing of the other project. A key reused in the same project still returns its task (C-P3.6 K2, frozen `TasksTest`). Refusing the same key with *different content* contradicts frozen C-P3.5 and C-P3.6 tests and is **not** done here: §5. |
| R10 | **No sentinel** (finding 10). `chooseChecksExpecting` takes `ExpectNothing` or `ExpectProfile id`. The checks form keeps `expected` and adds `expected_set` (`no` when nothing is chosen, `yes` otherwise); with `expected_set` the value of `expected` is taken literally, so a Profile called `none` works. A form without `expected_set` (and the C-P3.7 `chooseChecks` text API) reads `none` as "nothing chosen" only: when a Profile called `none` is the current choice, such a request is refused `checks-changed` (it cannot be told apart, so it fails closed). No Profile ID is restricted. |
| R11 | **Words.** `decision-busy`: "Someone else is answering this right now. Nothing was changed. Try again in a moment."; `decision-outcome-uncertain`: "Lockstep cannot tell whether this answer was recorded. Nothing more was done. Here is how it stands now."; `revision-out-of-range`: the form-error sentence. Projects: `project-busy` "This project is being set up right now. Nothing was changed. Try again in a moment.". Tasks: `key-conflict` "This form was already used for another project. Nothing was changed. Open New task again.". |
| R12 | **Launcher PATH conflict** (dogfood finding 1, product). `lockstep setup-path` and a terminal `./lockstep` launch detect when `lockstep` on `PATH` resolves to another program than Lockstep's link, name that program, say how to run Lockstep (`<checkout>/lockstep`, or `./lockstep` in the checkout), and mention an active virtual environment when one is the cause. Nothing outside `~/.local/bin/lockstep` is created, changed or removed; exit codes are unchanged. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | integration: real PostgreSQL, Git, in-process; two service pools for real concurrency | R1: two concurrent requests with one key and different content → one applied and one `key-conflict`, one receipt, outcome `applied`; with the same content → one applied, one replayed; a key whose lock is held elsewhere → `decision-busy` after the bound, nothing recorded; the lock connection killed while the operation waits → no receipt, the ledger change stands, the same key then `decision-outcome-uncertain` and nothing more; attempt markers immutable. R3: −1 and 2³¹ refused before any receipt. R4: current right after, not current once the work changed elsewhere. R5: two concurrent connects of one project → one Engineer, one registration, one folder; a failure at the Engineer, the registration or the project write → no Engineer, no registration, no new folder, project unchanged. R7: a task decision waits for the task lock; a stale Ticket revision after a title edit is `stale-revision`. R9: a key from another project is `key-conflict`. R10: a Profile called `none`. |
| `test/integration/Lockstep/GateCRemediationPageTest.hs` | integration: real service over HTTP | R3: out-of-range and non-decimal `expected`, `ticket_revision` and `revision` answer the form error and record nothing; R4: a closed decision changed elsewhere shows no Done page; R8: the hostile title escaped in the raw page; R10: `expected_set` on the checks page |
| `test/integration/Lockstep/GateCRemediationFolderTest.hs` | integration: real `scripts/service` with the docker stub (C-P3.5 support), real launcher | R6: a listed symbolic link and a listed path under a symbolic-link parent are not mounted; R12: a `lockstep` earlier on `PATH` is named, the link is still made, the other program is untouched |
| `test/integration/Lockstep/GateCRemediationBrowserTest.hs` | integration: headless Chromium (frozen `test/browser/app_driver.py`), real service | R8: the task page with the hostile title has no `onfocus` or `autofocus` attribute, and the title field holds the exact text |

Not covered by a deterministic test (recorded, not hidden): the helper's check-then-write window in
R6 (a symbolic link re-targeted between the check and the write needs a local race on the owner's
own home folder; the single in-shell check removes the second resolution, and the mount-time check
of R6 is tested).

## 3a. Verification record (after implementation)

To be filled after implementation.

## 4. Freeze record

Frozen 2026-10-27 by the writing agent (manual), before any of the fixes was implemented.

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | `8e7beb24a0ef48b86eec4a8368d2f180cf2be105ed63c074a45c88f55e01a9c8` |
| `test/integration/Lockstep/GateCRemediationPageTest.hs` | `4015a2835ae35a6ec3dc018efb31aa0d12e78fc7244203b1cd62a1676c4bd41d` |
| `test/integration/Lockstep/GateCRemediationFolderTest.hs` | `6497ba92949811893e5e61cdfacba234653a2b4518ebdfc2e84fef141b92e18f` |
| `test/integration/Lockstep/GateCRemediationBrowserTest.hs` | `d95ecee895ef0a1f3ea72effb153799643e6e6f85fcdc054f3f322c45ea652a9` |
| `test/integration/Main.hs` (runner, additive) | `fd71561c3342b6c788aeeebf4dea9f882b8546f487a0d67068555d1c34f51982` |

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
