# Gate C (C-UX) — decision packet and consolidated status

- For: the owner and the Planner. Prepared 2026-10-27 by the writing agent (Implementer, manual),
  revised after the Planner's Review 6 disposition (`.local/plans/phase-03_update5.md`). The
  Implementer cannot accept Gate C; this packet recommends.
- **Qualified candidate: `36cff9b`** on `phase-3` (production code `fd5bb90`: P3.1–P3.10 + the
  C-C.R1 remediation and its four addenda; A-C.R1-4 applied). Full record: `gate-c-report.md`;
  remediation: `docs/gates/C-R1/contract.md`.
- **Status: NOT ACCEPTED. Machine qualification PASSED on Mac and on a Linux clean clone
  (2026-10-27).** No Planner decision is outstanding. Open: C8, C9 and the owner's Gate C decision.
  Nothing installed, no legacy page retired, Phase 4 not started.

## 0. What the Planner's Review 6 disposition asked, and where it stands

| Asked | Done | Evidence |
|---|---|---|
| Never recursively delete a published folder; only private staging is removed | **Done** (R6-1): all post-publication removal deleted; the removal helper is unexported and only ever sees the `mkdtemp` workspace; a kept folder is offered again and the project page says so | `fd5bb90`; C-C.R1 §3e |
| #1 Data loss: cover replacement during a failed attempt; prove the replacement intact | **Done**: frozen case — file, commit and remotes of the replacement checked after the attempt | `GateCRemediationRetainTest.hs` |
| #2 Stale fallback: compare with the identity of the observation actually registered, `origin` included; mismatch `folder-not-offered` | **Done** (R6-2): before the Engineer and again right before each registration | same; two-remote replacement case |
| #3 CLI race: keep projects → repositories; serialize ownership checks; never remove repository data | **Done** (R6-3): no removal remains, so the only ownership check is C-P2.1's under the registration lock (CLI and attempts alike); no new lock | same; uncommitted CLI registration case |
| One addendum, frozen first | **Done**: frozen in `a518450`; 5 of 5 failed against `671b957`, each for its finding | `addendum4-prefreeze-baseline.log` |
| Conflicting frozen tests: exact diff and digests, one authorization | **Authorized and applied**: A-C.R1-4, three cases, at the authorized digests | `docs/gates/C-R1/amendment-request-4.md`; C-C.R1 §4, §5 |
| One focused read-only review | **Done** (Review 7): no HIGH, no MEDIUM; 1 LOW + 4 INFO recorded, not remediated; no reason to disable new-folder creation | `review.md`, Review 7 |

## 1. Machine evidence

| Check | Result |
|---|---|
| Format, lint, pedantic build, unit at `fd5bb90` | PASSED; unit 800 of 800 |
| Targeted integration at `fd5bb90` (C-C.R1 all addenda, C-P3.5, C-P3.6, C-P3.7) | **101 of 104**; the 3 are exactly A-C.R1-4's cases, failing only because the folder is now kept |
| Same C-C.R1 groups with the A-C.R1-4 diffs (trial; the applied files are byte-identical to it) | 40 of 40 |
| Frozen tests | every digest as recorded (C-C.R1 §4); the three A-C.R1-4 files at their authorized digests |
| Mac `scripts/check --integration` of `36cff9b` | **PASSED**: format, lint, build, unit 800/800, guard, integration **422/422**, backup/restore (`docs/gates/C-R1/check-integration-36cff9b.log`) |
| Linux clean clone of `36cff9b` | **PASSED**: format, lint, build, unit 800/800, integration **422/422**; case-sensitive; kernel boundary and purity scan clean (`docs/gates/C-R1/linux-clone-36cff9b.log`) |
| Last full qualification, `e1c56ef` | Mac and Linux each 402 of 403; the 1 was a frozen fixture since repaired (A-C.R1-2) |
| Independent read-only reviews (agents, not humans) | first review and Reviews 2–6: every HIGH/MEDIUM/LOW fixed under Planner authorization; Review 7 (final): no HIGH, no MEDIUM |

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

"Automated PASSED" is from the qualification of `36cff9b` (Mac and Linux, 422 of 422). The dogfood ran on the installed build `b963527`, not on the candidate
(which adds migrations 16 and 17 and has not been installed).

## 3. Decisions needed, in order

1. ~~Planner — A-C.R1-4~~: **done** (final authorization; applied at the authorized digests).
2. ~~Owner — consolidated qualification~~: **done**, both PASSED at `36cff9b`.
3. **C8**: the owner's browser walkthrough deferred from Gate B (about 20 minutes).
4. **C9**: the usability protocol with at least 3 first-time participants; PASSED only if every one
   completes J1–J8 unaided, or the owner accepts named exceptions in writing.
5. Optional, separate authorization: install the candidate on the owner's Mac and repeat the
   dogfood on it (it upgrades the database to schema 17).

## 4. Known exceptions and residual risks (recorded)

- Each request holding a session lock uses one extra database connection (bound it before Phase 4's
  concurrent workloads; Planner, deferred to Phase 4).
- An interrupted decision leaves "cannot tell" for its key, never a guessed receipt; a reloaded page
  has a fresh key.
- A creation key from before migration 17 replays only when the request is shown equal; otherwise it
  is refused.
- **A failed project attempt keeps any folder it published** (R6-1). It may be an orphan; it is
  offered again and can be connected with Try again. Repeated failures leave `name`, `name-2`, ….
- Folder identity is (device, inode); a `.git` re-created by someone else within the
  observation-to-transaction window on a filesystem that reuses inodes immediately could pass the
  check (Review 7 LOW; it needs a concurrent replacement of the folder by the same user).
- The helper's add-folder check-to-write window and an asynchronous exception exactly during the
  unlock have no deterministic tests (code review only).
- Review 6/7 LOW/INFO, recorded and not remediated under the stopping rule: an empty `.git` or a link
  swapped into a just-claimed destination during publication; an asynchronous exception leaving an
  unrecorded published folder, an empty claimed folder or a `.lockstep-new-*` directory (none
  offered, nothing lost); a mismatch found right before registration records the attempt with its
  new Engineer, as any registration refusal does.

## 5. Recommended disposition

1. The qualification is green: **accept the C-UX engineering and machine evidence (C1–C7)** at
   `36cff9b` and end Phase 3 remediation there:
   Review 7 found nothing at MEDIUM or above, and no further remediation round is proposed.
2. **Do not accept Gate C as a whole yet**: C9 is a gate requirement (PRD FR-UX-10: an automated run
   is not evidence that a person succeeded), and C8 is the walkthrough Gate B was deferred into.
3. If the owner decides to accept without C9, record it as a **named exception with its reason**,
   not as PASSED, and keep the cookie-page retirement, the installation and Phase 4 as separate
   authorizations.

| Decision | |
|---|---|
| A-C.R1-4 authorized (date) | 2026-10-27 (Planner, final); applied |
| Consolidated qualification: go-ahead given (date) | 2026-10-27 (owner); PASSED on Mac and Linux at `36cff9b` |
| C8 result | |
| C9 result, or named exception | |
| Gate C: accepted / accepted with exceptions / not accepted | |
| Decided by / at | |
