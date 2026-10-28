# Gate C (C-UX) — status and decision packet

- Status: **ACCEPTED WITH EXCEPTIONS** (the owner, 2026-10-27; `docs/governance/DECISION_REGISTER.md`).
  The candidate `36cff9b` (code `fd5bb90`) is QUALIFIED: Mac `scripts/check --integration` and a
  Linux clean clone, each unit 800 of 800 and integration 422 of 422, backup/restore PASSED on the
  Mac. **C8 and C9: NOT_RUN — DEFERRED BY OWNER** (named exceptions, carried into the Phase 4
  backlog). **Phase 4 not started** (owner's instruction). The concise
  decision packet is `decision-packet.md`. The Implementer cannot accept Gate C (Phase 3 handoff
  P3.11). C8 and C9 are **NOT_RUN**. Phase 4 is not started and will not be without the owner's
  authorization.
- Revision 3, 2026-10-27, updated after the Planner's final authorization of the same day
  (`.local/plans/phase-03_update4.md`), by the writing agent (Implementer, manual). Revision 2 was at
  `bd94c96` (§7).
- Branch `phase-3` (from `v2` at `8e71039`). Last fully qualified commit: **`e1c56ef`** (the P3.10
  code + the C-C.R1 remediation `e49b68e` + its review fixes). Since then, **not qualified**:
  `e679d97` (the authorized amendments A-C.R1-1, -2, -3 and the frozen addendum suite),
  `d064150` (migration 17, R13, R14), `11a035d` (second addendum frozen, from Review 4),
  `b9f7d47` (R13a, R13b, R9a), `33e0beb` (third addendum frozen, from Review 5), `671b957`
  (R5-1, R5-2, R5-3), `a518450` (fourth addendum frozen, from Review 6) and **`fd5bb90`** (R6-1,
  R6-2, R6-3). **Next qualification: one Mac `scripts/check --integration` and one Linux clean
  clone of the tip of `phase-3`** (code `fd5bb90`, with the applied A-C.R1-4 test amendment; the
  commit that records it, or a later documents-only commit).
- Authority: Phase 3 handoff P3.11; PRD v0.3 FR-UX-01…10, NFR-15…18; Plan v0.3 §4 P3.11; the
  Planner disposition of 2026-10-27.

## 1. At a glance

- **Both MEDIUM findings are fixed**, and so are the LOW and INFO ones, under the remediation
  contract **C-C.R1** (`docs/gates/C-R1/contract.md`), whose 21 regression cases were frozen before
  any fix and failed against the old code for the reasons the findings gave.
- **Machine verification at `e1c56ef`:** Mac 402 of 403 integration cases, unit 800 of 800; Linux
  clean clone the same (402 of 403, unit 800 of 800). The one failing case is a defect in a frozen C-C.R1 test's own fixture,
  not in the product (A-C.R1-2, below); with the proposed one-hunk fix it passes.
- **Owner's dogfood:** PASSED, steps 1–11, recorded as the human evidence for C1–C4 as far as it went
  (§2).
- **Since then (2026-10-27, Planner's final authorization):** A-C.R1-1, -2 and -3 applied at their
  authorized digests; migration 17 binds creation keys to request content; a connected project's
  folder is never removed, by any attempt of any project (Review 4's MEDIUM, fixed); asynchronous
  exceptions propagate from the session lock. Targeted runs: 78 of 78 affected integration cases
  and 800 of 800 unit cases pass at `b9f7d47`; the full qualification is still to run (§5a).
- **Waiting on the owner:** the go-ahead for the consolidated qualification, then the Gate C
  decision. What is and is not verified, and the next actions: §5a.

## 2. Scenario matrix

| Scenario | Automated evidence | Human evidence (owner dogfood, 2026-10-27, on `b963527`) | Result |
|---|---|---|---|
| C1 First launch | C-P3.1–C-P3.4 browser tests; C-P3.10 first-use journey | `./lockstep` opened the pane in the owner's default browser (step 1); Open Lockstep → Home, signed in (step 4) | automated PASSED; **human PASSED** as exercised (one product finding: a `.venv` program named `lockstep` shadowed the command; now C-C.R1 R12) |
| C2 Returning user | C-P3.2 lifecycle; C-P3.6/C-P3.9 the same words after a restart | stop and start of service and database from the pane, project, task and checks unchanged (step 10) | automated PASSED; **human PASSED** as exercised |
| C3 Upgrade and recovery | C-P3.3 (backup, verified backup, migration, failed upgrade recoverable) | upgrade of the owner's installation `6c2851d` → `b963527`, schema 5 → 15, through the pane (step 2) | automated PASSED; **human PASSED** for a successful upgrade; recovery from a failed upgrade was **not** exercised by a person |
| C4 Project onboarding | C-P3.5, C-P3.7 | an owner folder added read-only, a project made in it, a task made ready, checks chosen, the folder unchanged afterwards (steps 3, 5–7, 11) | automated PASSED; **human PASSED** as exercised |
| C5 Tasks | C-P3.6; C-C.R1 R7, R9 | (step 6 only) | automated PASSED |
| C6 Decisions | C-P3.8; C-C.R1 R1–R4 | (step 8: the empty Decisions page only) | automated PASSED |
| C7 Evidence | C-P3.9 | (step 9: the empty Activity page only) | automated PASSED |
| C8 Deferred Gate B walkthrough | — | — | **NOT_RUN — DEFERRED BY OWNER** (named exception; Phase 4 backlog) |
| C9 Nontechnical usability | C-P3.10 automated journey (not evidence that a person succeeded) | — | **NOT_RUN — DEFERRED BY OWNER** (named exception; Phase 4 backlog) |

Human and automated evidence stay distinct: the human column is what the owner reported doing and
seeing (the writing agent recorded it and did not observe it); "as exercised" means only the steps
listed, on the build named. Decisions, evidence and agent work were not exercised by a person, since
nothing had run.

## 3. What was tested and what was installed

| Identity | What it is |
|---|---|
| `bd94c96` | Revision 2's qualification (Mac and Linux, 382 of 382) |
| `b963527` | The owner's installed build (`.local/install/VERSION`: `dirty false`, binary SHA-256 `72ce6570…7c5b`, matching the file; installed 2026-10-27T20:32:42Z; `ready 15`). The dogfood ran on it |
| `bd94c96` ↔ `b963527` | Same code: `b963527` adds four documents only; the Git trees of `src`, `app`, `scripts`, `static`, `test`, `package.yaml`, `stack.yaml.lock`, `Dockerfile` and the launcher are identical. Different binaries (built separately; byte-identity not claimed) |
| `e1c56ef` | Revision 3's qualification (§4). **Not installed, not dogfooded**; it adds migration 16 |

## 4. Machine verification at `e1c56ef`

| Check | Result | Evidence |
|---|---|---|
| Mac: format, lint (hlint, Henforcer, shellcheck), pedantic build, unit and property (800), no-live-model guard | PASSED | `docs/gates/C-R1/check-integration-e1c56ef.log` |
| Mac: integration (real processes, PostgreSQL 17, Git, headless Chromium) | **402 of 403**; the 1 failure is the A-C.R1-2 case. Backup/restore NOT_RUN (it follows only a green integration step) | same |
| Linux clean clone of `e1c56ef` | format, lint, build PASSED; unit 800 of 800; integration **402 of 403**, the same single A-C.R1-2 case; kernel boundary and purity scan clean; case-sensitive filesystem | `docs/gates/C-R1/linux-clone.log` |
| C-C.R1 groups with the proposed A-C.R1-2 diff (trial, then the frozen file restored) | 21 of 21 | `docs/gates/C-R1/trial-with-proposed-a-c.r1-2.log` (at `e49b68e`) |
| Frozen tests | every earlier digest as recorded; C-C.R1's at `docs/gates/C-R1/contract.md` §4 | — |
| Independent read-only review of the remediation (an agent, **not** a human) | no HIGH, no MEDIUM; 4 LOW fixed in `e1c56ef`, 4 INFO kept | `review.md`, Review 2 |
| Read-only review of the fixes `e49b68e..e1c56ef` (an agent) | no HIGH, no MEDIUM; 2 LOW, 2 INFO, **not yet fixed** (held for one combined qualification with A-C.R1-2, at the owner's request); one of them is contract text that trails the code (proposed A-C.R1-3) | `review.md`, Review 3 |

## 5. What is decided, and what you decide

| Item | Decision |
|---|---|
| Review dispositions 1–10 | **Decided** (Planner, 2026-10-27); implemented under C-C.R1 (`review.md` lists each) |
| #1 mechanism | **Option B**, session-level advisory lock, as built; no mutable receipt (attempt markers are a second append-only table) |
| #7 | Code changed to match C-P3.6 K2 (no contract amendment) |
| `.venv` shadowing | Product finding; C-C.R1 R12 and the setup instructions |
| Dogfood step 10 correction | Resolved |
| Review 2 (`review.md`) | **Decided** (Planner, 2026-10-27): the four LOW fixes in `e1c56ef` accepted **provisionally**, subject to the delta review (Review 3); INFO 6–8 accepted as documented; **INFO 5 deferred to Phase 4** (bounded concurrency for lock connections, to be addressed before concurrent live-engineering workloads) |
| **A-C.R1-1** (`docs/gates/C-R1/amendment-request-1.md`): bind a creation key to the request's content | **Approved** (Planner, final, 2026-10-27) and **applied** (`e679d97`, `d064150`: migration 17) |
| **A-C.R1-2** (`docs/gates/C-R1/amendment-request-2.md`): repair one frozen C-C.R1 page fixture | **Approved** and **applied** (`e679d97`); production limits unchanged |
| **A-C.R1-3** (`docs/gates/C-R1/amendment-request-3.md`): R1 step (2) states the marker digest rule; one new frozen case | **Approved** and **applied** (`e679d97`) |
| Review 3 (`review.md`) corrections | **Authorized** and **implemented** (`d064150`, C-C.R1 §3b R13–R15), with a frozen addendum suite and a test-only post-commit hook |
| Consolidated Mac qualification and Linux clean clone of the tip | **Owner**: when to start (not before the owner's go-ahead) |
| C1–C4 human results | Recorded as PASSED as exercised by the dogfood (§2); the owner may add or correct |
| C8, C9 | NOT_RUN |
| Gate C accepted / not accepted, with exceptions | |
| Decided by / at | |

Not started without authorization: the consolidated qualification, cookie-page retirement
(deferred, option c), installing the remediation on the owner's Mac, and Phase 4.

## 5a. Verified and not verified (2026-10-27, at the stop before qualification)

| Item | Status |
|---|---|
| `e1c56ef` on the Mac and a Linux clean clone | **Qualified**: 402 of 403 each (the 1 being the fixture A-C.R1-2 has since repaired) |
| A-C.R1-1, -2, -3 in the frozen tests | **Applied** at the authorized digests (checked before and after) |
| Migration 17, R13, R14 (`d064150`) and R13a, R13b, R9a (`b9f7d47`) | **Verified by targeted runs only**: format, lint, pedantic build, unit 800 of 800; integration groups C-C.R1 (with both addenda), C-P3.5, C-P3.6: 78 of 78 at `b9f7d47` (`docs/gates/C-R1/addendum2-implementation-run.log`); every amended or new case failed before for its finding (`addendum-prefreeze-baseline.log`, `addendum2-prefreeze-baseline.log`) |
| The tip across the whole suite (Mac and Linux) | **QUALIFIED at `36cff9b`** (code `fd5bb90`): Mac format, lint, build, unit 800/800, guard, integration 422/422, backup/restore PASSED (`docs/gates/C-R1/check-integration-36cff9b.log`); Linux clean clone format, lint, build, unit 800/800, integration 422/422, case-sensitive, kernel boundary and purity scan clean (`docs/gates/C-R1/linux-clone-36cff9b.log`) |
| R14 under a real asynchronous exception during the unlock | Not testable deterministically; code review only |
| Read-only code review of `e1c56ef..d064150` (Review 4) | 1 MEDIUM, 1 LOW, 3 INFO; MEDIUM and LOW fixed in `b9f7d47` (`review.md`) |
| Read-only check of `d064150..b9f7d47` (Review 5) | no HIGH, no MEDIUM; 3 LOW, **fixed in `671b957`** under the Planner's final authorization (C-C.R1 §3d); 5 frozen cases, failing before, passing after; targeted 99 of 99 |
| Independent read-only review of `b9f7d47..671b957` (Review 6) | 3 MEDIUM; **corrected in `fd5bb90`** under the Planner's final engineering authorization (C-C.R1 §3e): no published folder is ever removed; the identity of the observation actually registered is checked, `origin` fallback included; ownership is checked only under the registration lock. 5 frozen cases, failing before, passing after; targeted 101 of 104 (the 3 being A-C.R1-4's cases); unit 800 of 800 |
| A-C.R1-4 (`docs/gates/C-R1/amendment-request-4.md`) | **Authorized (final) and applied** at the authorized digests; the applied files are byte-identical to the trial copies that passed 40 of 40 at `fd5bb90` |
| Final focused read-only review of `fd5bb90` (Review 7) | **no HIGH, no MEDIUM**; 1 LOW, 4 INFO recorded (`review.md`) |
| The remediation on the owner's installation | **Not installed, not dogfooded** (it adds migrations 16 and 17) |
| Gate C | **Not accepted**. C8, C9 NOT_RUN |

Next required actions, in order:

1. ~~Planner: A-C.R1-4~~ — **done** (authorized and applied; no Planner decision outstanding).
2. ~~Owner: release the hold~~ — **done** (2026-10-27).
3. ~~Implementer: qualification~~ — **done**, both green at `36cff9b` (above). Kept as written: **one** Mac `scripts/check --integration` and **one** Linux clean clone
   (`.local/linux-clone-run-cr1.sh <commit>`), both on the tip of `phase-3`; record both here and in
   C-C.R1 §3a. No intermediate full runs.
4. The Gate C decision by the owner (C8 and C9 still open; Phase 4, cookie-page retirement and
   installing on the owner's Mac only with the owner's authorization).

## 6. Residual risks, stated

- Phase 4 carry-forward (Planner, 2026-10-27): each locked request opens one extra database
  connection; bound this before concurrent live-engineering workloads.

- A crash between a decision's operation and its receipt leaves a marker and no receipt; that key
  then answers "cannot tell", never a guessed receipt (C-C.R1 §3a).
- A failed project attempt keeps any folder it published, always (C-C.R1 R6-1): an orphaned new
  folder is preferred to deleting someone else's repository. Kept folders are offered again, so Try
  again can connect one; they accumulate (`name`, `name-2`, …) if attempts keep failing.
- Folder identity is (device, inode); a `.git` re-created by someone else inside the
  observation-to-transaction window on a filesystem that reuses inodes at once could pass the
  check (Review 7 LOW; recorded).
- A creation key made before migration 17 replays only when the request is shown equal; a new-folder
  project request of that age always conflicts (fails closed).
- The helper's check-then-write window for an added folder has no deterministic test; the mount-time
  re-check that closes it is tested.

## 7. Earlier records

- Revision 2 at `bd94c96`: `qualification-check-r2.log`, `qualification-linux-clone-r2.log`
  (382 of 382 each). Revision 1 at `0c8d9ee`: `qualification-check.log`,
  `qualification-linux-clone.log`.
- Phase 3 contracts: P3.1 … P3.10 as listed in revision 2 (`git show b963527:docs/gates/C/gate-c-report.md`),
  plus C-C.R1 (`docs/gates/C-R1/contract.md`; freeze `b83db50`, implementation `e49b68e`, review
  fixes `e1c56ef`).
