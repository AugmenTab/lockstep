# Gate C (C-UX) — status and owner-review packet

- Status: **READY FOR OWNER REVIEW; NOT ACCEPTED.** The Implementer cannot accept Gate C
  (Phase 3 handoff P3.11). The human-only scenarios are **NOT_RUN**.
- Revision 2, 2026-10-27, after the Planner disposition of the same day (writing agent,
  Implementer, manual). Revision 1 was at `0c8d9ee`; its logs are kept (§6).
- Branch `phase-3` (from `v2` at `8e71039`). Tested commit: **`bd94c96`** = the P3.10 code
  (`0c8d9ee`) + documents + the approved `HandoverTest.hs` amendment A1. No production code changed
  after `0c8d9ee`.
- Authority: Phase 3 handoff P3.11; PRD v0.3 FR-UX-01…10, NFR-15…18; Plan v0.3 §4 P3.11.

## 1. At a glance

- **Machine verification is green:** every automated check passes on the Mac and on a Linux clean
  clone, browser tests included (§3).
- **Decided by the Planner (2026-10-27):** the `HandoverTest.hs` amendment was approved and
  applied; cookie-page retirement is **deferred until after Gate C-UX** (option c).
- **Waiting on you:** the dogfood checkpoint, the owner scenarios C1–C4 and C8, the participant
  test C9, the review dispositions, and the Gate C decision itself (§5).

## 2. Scenario matrix

| Scenario | Automated evidence (what a machine proved) | Human part | Result |
|---|---|---|---|
| C1 First launch | C-P3.1–C-P3.4 browser tests (control pane in real Chromium, Open Lockstep → Home, keyboard, phone width, hostile page refused, sign-out); C-P3.10 first-use journey | `./lockstep` on your Mac opens the pane in your **default browser** | automated PASSED; human **NOT_RUN** |
| C2 Returning user | C-P3.2 lifecycle (start, stop, restart without rebuild or migration); C-P3.6 and C-P3.9 same words after a restart | reopening your own installation | automated PASSED; human **NOT_RUN** |
| C3 Upgrade and recovery | C-P3.3 install/upgrade (backup, verified backup, migration, failed upgrade recoverable) | upgrading your installation (`6c2851d`, schema 5 → 15) through the pane | automated PASSED; human **NOT_RUN** |
| C4 Project onboarding | C-P3.5 (projects, host-decided folders, real Docker mount probe); C-P3.7 (checks per project) | registering one of your own repositories | automated PASSED; human **NOT_RUN** |
| C5 Tasks | C-P3.6: create, edit, prioritize, depend, block, readiness; durable across a restart; nothing runs | — | automated PASSED |
| C6 Decisions | C-P3.8: stopped work and unknown outcomes decided as a Human, with receipts; stale, replayed and conflicting requests refused | — | automated PASSED |
| C7 Evidence | C-P3.9: statuses from the database, honest labels, raw evidence, the same after a restart | — | automated PASSED |
| C8 Deferred Gate B walkthrough | — | your browser review deferred from Gate B (`docs/gates/B/decision-packet.md`); the cookie pages stay available for it (retirement deferred) | **NOT_RUN** |
| C9 Nontechnical usability | C-P3.10 automated journey only, which is **not** evidence that a person succeeded | real first-time participants, `docs/gates/P3.10/usability-protocol.md` | **NOT_RUN** |

C1–C4 are covered in one sitting by the dogfood checkpoint (§4).

## 3. Machine verification at `bd94c96`

| Check | Result | Evidence |
|---|---|---|
| Mac: format, lint (hlint, Henforcer), pedantic build, unit and property (800), no-live-model guard | PASSED | `qualification-check-r2.log` |
| Mac: integration (real processes, PostgreSQL 17, Git, headless Chromium) and backup/restore | **382 of 382 PASSED**, both amended `HandoverTest.hs` cases included; the first-use journey took 336 s (limit 400 s) | `qualification-check-r2.log` |
| Linux clean clone of `bd94c96` | format, lint, build PASSED; unit 800 of 800; **integration 382 of 382 PASSED**; kernel boundary and purity scan clean; exit 0 | `qualification-linux-clone-r2.log` |
| Frozen tests | every digest as recorded; `HandoverTest.hs` at its amended digest `8a9903a9…1da0` (C-P3.4 §4, A1) | `docs/gates/P3.4/contract.md` |
| Independent read-only review (an agent, **not** a human review) | no HIGH; 2 MEDIUM, 5 LOW, 3 INFO; dispositions proposed, nothing changed | `review.md` |

The Mac run's tree was `bd94c96` plus uncommitted documents only (this packet and the dogfood
checkpoint).

## 4. Start here: the dogfood checkpoint

`docs/gates/P3.6/dogfood-checkpoint.md`: about 20 minutes on your own Mac, against your current
installation. It upgrades it (schema 5 → 15), adds one of your own repositories read-only, creates
a project and a ready task, chooses checks, and looks at Decisions and Activity. Nothing runs an
agent or a model, and nothing is pushed. Its table is the record for C1–C4.

## 5. What is decided, and what you decide

| Item | Decision |
|---|---|
| Amend `HandoverTest.hs` (`drop 7` → `drop 6`) | **APPROVED and applied** (Planner, 2026-10-27); re-frozen; passing on Mac and Linux |
| Retire the cookie pages | **(c) deferred until after Gate C-UX** (Planner, 2026-10-27): no new capabilities for them, users go through the application only, Gate B walkthrough still possible; final retirement needs its own exact amendment set |
| Review dispositions 1–10 (`review.md`): accept as proposed / change. #1 needs a mechanism choice (a or b); #7 a choice between amending C-P3.6 K2 and changing the code | |
| Dogfood checkpoint / C1–C4 human results | |
| C8 result (your Gate B walkthrough) | |
| C9 results (real participants) | |
| Gate C accepted / not accepted, with exceptions | |
| Decided by / at | |

Not started without your authorization: any fix from `review.md`, cookie-page retirement, and
Phase 4 (the first real local single-Engineer coding transaction).

## 6. Earlier and supporting records

- Revision 1 at `0c8d9ee`: `qualification-check.log` (Mac) and `qualification-linux-clone.log`
  (Linux); both 380 of 382, the 2 failures being the `HandoverTest.hs` defect since amended.
- Two one-off browser-driver timeouts in unrelated cases happened during the phase (C-P1.x
  `BrowserFormTest` in a P3.7 run; C-P3.8 `DecisionsBrowserTest` in a P3.10 run that took twice
  its usual time). Both passed in every other run, Mac and Linux. The logs are kept.
- Phase 3 contracts:

| Sub-phase | Contract | Implementation | Linux clean clone |
|---|---|---|---|
| P3.1 control pane | `docs/gates/P3.1/contract.md` | `9584454` | `e664e2c` |
| P3.2 lifecycle | `docs/gates/P3.2/contract.md` | `767731b` | `dee7f8c` |
| P3.3 install and upgrade | `docs/gates/P3.3/contract.md` | `614f56c` | `d41d3da` |
| P3.4 application shell | `docs/gates/P3.4/contract.md` (amendment A1) | `21dad60` | `7738782` |
| P3.5 projects | `docs/gates/P3.5/contract.md` | `9d4221a` | `b2162e0` |
| P3.6 tasks | `docs/gates/P3.6/contract.md` | `3adc064` | `f3fb585` |
| P3.7 checks and what can start | `docs/gates/P3.7/contract.md` | `3aa99b6` | `50385a7` |
| P3.8 decisions | `docs/gates/P3.8/contract.md` | `3e614d6` | `bf78e91` |
| P3.9 activity and evidence | `docs/gates/P3.9/contract.md` | `3cb9b1f` | `3866fd3` |
| P3.10 first-use journey | `docs/gates/P3.10/contract.md` | `0c8d9ee` | this packet, §3 |
