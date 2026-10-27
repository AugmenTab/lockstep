# Gate C (C-UX) — qualification package for the owner

- Status: **READY FOR HUMAN EVALUATION; NOT ACCEPTED.** The Implementer cannot accept Gate C
  (Phase 3 handoff P3.11). Several required scenarios are human-only and are **NOT_RUN**.
- Prepared: 2026-10-27 by the writing agent (Implementer, manual).
- Branch `phase-3` (from `v2` at `8e71039`); tested commit: **`0c8d9ee`** (the P3.10 implementation). Everything after it
  in the branch is documentation.
- Authority: Phase 3 handoff P3.11; PRD v0.3 FR-UX-01…10, NFR-15…18; Plan v0.3 §4 P3.11 ("C-UX
  qualification, Gate B deferred-browser walkthrough and human decision packet"; "unresolved
  participant checks NOT_RUN").

## 1. Scenario matrix

| Scenario | Automated evidence (what a machine proved) | Human part | Result |
|---|---|---|---|
| C1 First launch | C-P3.1–C-P3.4 browser tests: the control pane in real Chromium, Open Lockstep → Home, keyboard, phone width, a hostile page refused, sign-out; C-P3.10 first-use journey | the owner runs `./lockstep` on their own Mac and the **default browser** opens the pane | **NOT_RUN** (owner-only) |
| C2 Returning user | C-P3.2 lifecycle tests (start, stop, restart without rebuild or migration); C-P3.6 and C-P3.9 restarts with the same words | the owner reopens their own installation | **NOT_RUN** (owner-only) |
| C3 Upgrade and recovery | C-P3.3 install/upgrade tests (backup, verified backup, migration, failed upgrade recoverable) | upgrading the operator's own installation (`6c2851d`, schema 5) through the pane | **NOT_RUN** (owner-only; `docs/gates/P3.6/dogfood-checkpoint.md` step 2) |
| C4 Project onboarding | C-P3.5 (projects, host-decided folders, real Docker mount probe) and C-P3.7 (checks per project) | registering one of the owner's own repositories (dogfood checkpoint) | automated PASSED; human **NOT_RUN** |
| C5 Tasks | C-P3.6: create, edit, prioritize, depend, block, readiness; durable across a restart; no execution | — | automated PASSED |
| C6 Decisions | C-P3.8: stopped work and unknown outcomes decided as a Human with receipts; stale, replayed and conflicting requests refused | — | automated PASSED |
| C7 Evidence | C-P3.9: statuses from the database, honest labels, raw evidence, identical after a restart | — | automated PASSED |
| C8 Deferred Gate B walkthrough | — | the owner's browser review deferred from Gate B (`docs/gates/B/decision-packet.md`) | **NOT_RUN** (owner) |
| C9 Nontechnical usability | C-P3.10 automated journey only, which is **not** evidence that a person succeeded | real first-time participants, `docs/gates/P3.10/usability-protocol.md` | **NOT_RUN** |

## 2. Standard checks at the tested commit

| Check | Result | Evidence |
|---|---|---|
| Format, lint (hlint, Henforcer boundaries), pedantic build, unit and property tests, no-live-model guard (Mac) | PASSED | `qualification-check.log` (the tree was the tested commit plus uncommitted documentation only) |
| Integration on the Mac (real processes, real PostgreSQL 17, real Git, headless Chromium) | 380 of 382 PASSED; the 2 failures are the `HandoverTest.hs` defect (§3.1) | `qualification-check.log` |
| Linux clean clone of `0c8d9ee` | format, lint, build, unit PASSED; integration 380 of 382, the same 2 cases in count; every C-P3.8–C-P3.10 case in the kept tail passed | `qualification-linux-clone.log` |
| Independent read-only review (an agent, **not** a human review) | no HIGH; 2 MEDIUM (a decision receipt can contradict the outcome under concurrent same-key requests; concurrent project connects can leave an orphan Engineer and repository), 5 LOW, 3 INFO; dispositions proposed, nothing changed | `review.md` |

## 3. Known failures and open owner items

1. **`HandoverTest.hs`, 2 cases, fail in every run** because of a defect in the frozen test itself
   (`BS.drop 7` where the prefix is 6 bytes). The behaviour works end to end in the real-browser
   hand-over journey, which passes. Amendment requested: `docs/gates/P3.4/test-amendment-request.md`.
   Gate C cannot be accepted with this frozen test failing unless the owner amends it.
2. Retiring the Phase 1/2 cookie pages: `docs/gates/P3.4/retirement-request.md` (options a/b/c).
3. Early value checkpoint (dogfood): `docs/gates/P3.6/dogfood-checkpoint.md`, owner-only.
4. The review's two MEDIUM findings and five LOW findings (`review.md`): proposed to be fixed
   before Gate C acceptance, under contract amendments the owner approves; finding 1 needs the
   owner's choice of mechanism, finding 7 the owner's choice between amending C-P3.6 K2 and
   changing the code.
5. Two one-off browser-driver timeouts in unrelated cases during the phase (C-P1.x
   `BrowserFormTest` in the P3.7 run 2; C-P3.8 `DecisionsBrowserTest` in the P3.10 run 1, during
   which the whole run took twice its usual time). Both passed in every other run, Mac and Linux.
   Kept as logs; not hidden.

## 4. Phase 3 contracts

| Sub-phase | Contract | Implementation | Linux clean clone |
|---|---|---|---|
| P3.1 control pane | `docs/gates/P3.1/contract.md` | `9584454` | `e664e2c` |
| P3.2 lifecycle | `docs/gates/P3.2/contract.md` | `767731b` | `dee7f8c` |
| P3.3 install and upgrade | `docs/gates/P3.3/contract.md` | `614f56c` | `d41d3da` |
| P3.4 application shell | `docs/gates/P3.4/contract.md` | `21dad60` | `7738782` |
| P3.5 projects | `docs/gates/P3.5/contract.md` | `9d4221a` | `b2162e0` |
| P3.6 tasks | `docs/gates/P3.6/contract.md` | `3adc064` | `f3fb585` |
| P3.7 checks and what can start | `docs/gates/P3.7/contract.md` | `3aa99b6` | `50385a7` |
| P3.8 decisions | `docs/gates/P3.8/contract.md` | `3e614d6` | `bf78e91` |
| P3.9 activity and evidence | `docs/gates/P3.9/contract.md` | `3cb9b1f` | `3866fd3` |
| P3.10 first-use journey | `docs/gates/P3.10/contract.md` | `0c8d9ee` | see §2 |

## 5. What the owner decides

| Decision | Choice |
|---|---|
| Amend `HandoverTest.hs` (`drop 7` → `drop 6`) | |
| Retire the cookie pages (a / b / c) | |
| Review dispositions 1–10 (`review.md`): accept as proposed / change | |
| C1, C2, C3, C4-human, C8 results (owner walkthrough) | |
| C9 results (real participants) | |
| Gate C accepted / not accepted, with exceptions | |
| Decided by / at | |
