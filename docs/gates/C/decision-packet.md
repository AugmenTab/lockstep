# Gate C (C-UX) — decision packet

- For: the owner. Prepared 2026-10-27 by the writing agent (Implementer, manual). The Implementer
  cannot accept Gate C; this packet recommends.
- Candidate: the tip of `phase-3`, code at **`671b957`** (P3.1–P3.10 + the C-C.R1 remediation and its
  three addenda). Full record: `gate-c-report.md`; remediation: `docs/gates/C-R1/contract.md`.
- **Status: NOT ACCEPTED. The candidate's consolidated qualification has NOT RUN** (the owner's stop
  instruction). The results below marked *pending* are filled in after it.

## 1. Machine evidence

| Check | Result |
|---|---|
| Mac `scripts/check --integration` of the candidate | *pending* (not started: owner's go-ahead) |
| Linux clean clone of the candidate | *pending* (not started: owner's go-ahead) |
| Last full qualification, `e1c56ef` | Mac and Linux each 402 of 403; the 1 was a frozen fixture since repaired (A-C.R1-2) |
| Targeted runs at `671b957` | unit 800 of 800; the affected integration groups (C-C.R1 with all addenda, C-P3.5, C-P3.6, C-P3.7) 99 of 99 |
| Frozen tests | every digest as recorded; the 3 authorized amendments applied at their authorized digests |
| Independent read-only reviews (agents, not humans) | first review: 2 MEDIUM, 5 LOW, 3 INFO, all dispositioned; Reviews 2–5 of the remediation: their MEDIUM and LOW findings fixed under Planner authorization; Review 6 (R5-1–R5-3): **3 MEDIUM, escalated, not fixed** (one data-loss path in the folder cleanup) |

## 2. Scenarios

| | Automated | Human | Result |
|---|---|---|---|
| C1 First launch | PASSED | owner dogfood 2026-10-27, steps 1, 4 | PASSED as exercised |
| C2 Returning user | PASSED | dogfood step 10 | PASSED as exercised |
| C3 Upgrade and recovery | PASSED | dogfood step 2 (upgrade only; failed-upgrade recovery not done by a person) | PASSED as exercised |
| C4 Project onboarding | PASSED | dogfood steps 3, 5–7, 11 | PASSED as exercised |
| C5 Tasks, C6 Decisions, C7 Evidence | PASSED | — (C6, C7 seen empty only) | automated PASSED |
| **C8** Deferred Gate B walkthrough | — | the owner's browser walkthrough deferred from Gate B (`docs/gates/B/decision-packet.md`) | **NOT_RUN** |
| **C9** Nontechnical usability | journey automated only (not evidence) | at least 3 people new to Lockstep, journeys J1–J8, no help (`docs/gates/P3.10/usability-protocol.md`) | **NOT_RUN** |

The dogfood ran on the installed build `b963527` (same code as the then-tested `bd94c96`), not on the
candidate; the candidate adds migrations 16 and 17 and has not been installed.

## 3. Outstanding human-only requirements

1. **Go-ahead for the consolidated qualification** (one Mac, one Linux clean clone, on the candidate).
2. **C8**: the owner's browser walkthrough deferred from Gate B.
3. **C9**: the usability protocol with at least 3 first-time participants; PASSED only if every one
   completes J1–J8 unaided, or the owner accepts named exceptions in writing.
4. Optional, separate authorization: install the candidate on the owner's Mac and repeat the dogfood
   on it (it upgrades the database to schema 17).

## 4. Known exceptions and residual risks (recorded, accepted by the Planner or within contract)

- Each request holding a session lock uses one extra database connection (bound it before Phase 4's
  concurrent workloads; Planner, deferred to Phase 4).
- An interrupted decision leaves "cannot tell" for its key, never a guessed receipt; a reloaded page
  has a fresh key.
- A creation key from before migration 17 replays only when the request is shown equal; otherwise it
  is refused.
- A failed project attempt whose state or folder identity cannot be read keeps the folder it made.
- The helper's add-folder check-to-write window and an asynchronous exception exactly during the
  unlock have no deterministic tests (code review only).
- Review 6 LOW/INFO observations, recorded and not fixed under the Planner's stopping rule: an empty
  `.git` created inside a just-claimed destination, or a link swapped in for it, during
  publication; an asynchronous exception leaving an unrecorded published folder, an empty claimed
  folder or a `.lockstep-new-*` directory (none offered, nothing lost).

## 4a. Open: Review 6's three MEDIUM findings (escalated to the Planner)

All three need a folder replaced or registered by someone else during a project's connection
attempt; one of them can delete that other repository (`review.md`, Review 6, with the correction
plan). **The candidate should not be qualified as final until the Planner decides**: either a last
small addendum (frozen first; then the one consolidated qualification runs on that commit), or named
exceptions.

## 5. Recommended disposition

1. Let the Planner settle §4a first; then give the go-ahead for the consolidated qualification on
   the resulting commit. If it is green, **accept the C-UX engineering and machine evidence
   (C1–C7)**.
2. **Do not accept Gate C as a whole yet**: C9 is a gate requirement (PRD FR-UX-10: an automated run
   is not evidence that a person succeeded), and C8 is the walkthrough Gate B was deferred into. Run
   both; C8 takes about 20 minutes of the owner's time.
3. If the owner decides to accept without C9, record it as a **named exception with its reason**,
   not as PASSED, and keep the cookie-page retirement, the installation and Phase 4 as separate
   authorizations.

| Owner's decision | |
|---|---|
| Consolidated qualification: go-ahead given (date) | |
| C8 result | |
| C9 result, or named exception | |
| Gate C: accepted / accepted with exceptions / not accepted | |
| Decided by / at | |
