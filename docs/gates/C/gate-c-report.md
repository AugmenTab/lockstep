# Gate C (C-UX) — status and decision packet

- Status: **NOT ACCEPTED. Remediation implemented and qualified on the Mac at `e1c56ef`; amendments
  and a small correction plan wait for the Planner; no further qualification until the owner is
  back.** The
  Implementer cannot accept Gate C (Phase 3 handoff P3.11). C8 and C9 are **NOT_RUN**. Phase 4 is
  not started and will not be without the owner's authorization.
- Revision 3, 2026-10-27, after the Planner disposition of the same day
  (`.local/plans/phase-03_update2.md`), by the writing agent (Implementer, manual). Revision 2 was at
  `bd94c96` (§7).
- Branch `phase-3` (from `v2` at `8e71039`). Tested commit: **`e1c56ef`** = the P3.10 code + the
  C-C.R1 remediation (`e49b68e`) + the fixes from its independent review (`e1c56ef`). Documents after
  it are not code.
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
- **Waiting on the Planner:** final authorization of A-C.R1-1 and A-C.R1-2 (approved in principle),
  a decision on A-C.R1-3 and the Review 3 correction plan (§5), then the Gate C decision. What is
  and is not verified, and the next actions: §5a.

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
| C8 Deferred Gate B walkthrough | — | — | **NOT_RUN** |
| C9 Nontechnical usability | C-P3.10 automated journey (not evidence that a person succeeded) | — | **NOT_RUN** |

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
| **A-C.R1-1** (`docs/gates/C-R1/amendment-request-1.md`): bind a creation key to the request's content | **Approved in principle** (Planner); **final authorization pending**: exact diffs `a-c.r1-1-projects.diff`, `a-c.r1-1-tasks.diff`, before/after digests and the C-P3.5 J2 / C-P3.6 K2 wording are ready. Production change (migration 17) not written |
| **A-C.R1-2** (`docs/gates/C-R1/amendment-request-2.md`): repair one frozen C-C.R1 page fixture | **Approved in principle** (Planner); **final authorization pending**: `a-c.r1-2.diff`, after-digest `ad05170c…806e` |
| **A-C.R1-3** (`docs/gates/C-R1/amendment-request-3.md`): R1 step (2) states the marker digest rule; one new frozen case | **Requested** (from Review 3); not yet approved in any form |
| Review 3 (`review.md`) | Two of the four points verified, one verified in code but not by a frozen test (→ A-C.R1-3), one **not fully met** (a connected project's folder can be removed in two narrow windows); correction plan recorded, not applied |
| C1–C4 human results | Recorded as PASSED as exercised by the dogfood (§2); the owner may add or correct |
| C8, C9 | NOT_RUN |
| Gate C accepted / not accepted, with exceptions | |
| Decided by / at | |

Not started without authorization: cookie-page retirement (deferred, option c), installing
`e1c56ef` on the owner's Mac, and Phase 4.

## 5a. Verified and not verified (2026-10-27, at the stop)

| Item | Status |
|---|---|
| Code at `e1c56ef` on the Mac | **Verified**: 402 of 403 (the 1 being the fixture of A-C.R1-2) |
| Code at `e1c56ef` on a Linux clean clone | **Verified**: 402 of 403 (the same A-C.R1-2 case) |
| The four Review 2 fixes | Accepted provisionally; Review 3 done; one point not fully met (above) |
| The correction plan for Review 3 | **Not written in code, not verified** |
| A-C.R1-1, A-C.R1-2, A-C.R1-3 amended files | Prepared as copies and exact diffs only; **not compiled, not run, not applied** |
| A-C.R1-1 production change (migration 17) | **Not written** |
| `e1c56ef` on the owner's installation | **Not installed, not dogfooded** |
| Gate C | **Not accepted**. C8, C9 NOT_RUN |

Next required actions, in order (none started):

1. Planner: final authorization of A-C.R1-1 and A-C.R1-2; a decision on A-C.R1-3 and the Review 3
   correction plan.
2. Implementer (after the owner is back): apply the authorized amendments and re-freeze; write the
   A-C.R1-1 production change and the Review 3 corrections; show the amended cases failing before
   and passing after.
3. One Mac qualification and one Linux clean clone of the resulting commit; a read-only review of
   that delta.
4. The Gate C decision (C8 and C9 still open; Phase 4 only with the owner's authorization).

## 6. Residual risks, stated

- Phase 4 carry-forward (Planner, 2026-10-27): each locked request opens one extra database
  connection; bound this before concurrent live-engineering workloads.

- A crash between a decision's operation and its receipt leaves a marker and no receipt; that key
  then answers "cannot tell", never a guessed receipt (C-C.R1 §3a).
- A connected project's new folder can be removed in two narrow windows (an asynchronous exception
  after the commit, an ambiguous COMMIT); correction planned (`review.md`, Review 3).
- The helper's check-then-write window for an added folder has no deterministic test; the mount-time
  re-check that closes it is tested.

## 7. Earlier records

- Revision 2 at `bd94c96`: `qualification-check-r2.log`, `qualification-linux-clone-r2.log`
  (382 of 382 each). Revision 1 at `0c8d9ee`: `qualification-check.log`,
  `qualification-linux-clone.log`.
- Phase 3 contracts: P3.1 … P3.10 as listed in revision 2 (`git show b963527:docs/gates/C/gate-c-report.md`),
  plus C-C.R1 (`docs/gates/C-R1/contract.md`; freeze `b83db50`, implementation `e49b68e`, review
  fixes `e1c56ef`).
