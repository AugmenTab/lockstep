# Gate C-EXEC — decision packet

- For: the owner. Prepared 2026-10-28 by the writing agent (Implementer, manual). The Implementer cannot
  accept Gate C-EXEC or mark anything Done; this packet recommends.
- Branch `phase-4` (from `77a96ce`). Authority: `.local/plans/phase-04.md` (`24db39d9…`),
  `.local/plans/phase-04_update1.md` (`4cb620d3…`), `.local/plans/phase-04_update2.md` (`c3b2a6fd…`).
- **Qualified candidate: `54966a4`** (working tree clean). Mac `scripts/check --integration`: all six steps
  PASSED — unit 862/862, integration 562/562, backup/restore, no-live-model guard (sentinel log empty). Linux
  clean clone: unit 862/862, integration 562/562 (case-sensitive disks). Host: `check-runner` 0 failures,
  `check-runner-paths` 7/7 (real Docker); `lockstep-stress` PASS, 17 MB maximum residency for 384 MiB.
  Logs: `.local/p4r2-check-mac.log`, `.local/p4r2-linux.log`, `.local/p4r2-check-runner.log`,
  `.local/p4r2-runner-paths.log`, `.local/p4r2-stress.log`. This round: `cadd969..54966a4`; documents after it
  change no code.

## 1. What Phase 4 built, and its evidence

| Sub-phase | What | Frozen → implemented | Qualification |
|---|---|---|---|
| P4.1 | Allow Lockstep in a project (Bug Profile `lockstep-bug-fix` v1); hand over a ready task as a bug Work Order with no plan | `70b95d2` → `bd4512b` | Mac + Linux, `bd4512b` |
| P4.2 | Finite runners: direct process-group runner; the helper's container runner channel (`--runner`) | `b623d5d` → `ea9b445`, `b6385b6` (A-P4.2-1) | Mac + Linux, `b6385b6`; host container check 44/44 |
| P4.3 | Durable requests to a person and conversations; binding answers (person only, revision, once) | `ca44459` → `0fcb2b9`; A-P4.3-1 `4ee971d` | Mac + Linux, `4ee971d` |
| P4.4 | The Supervisor's Git boundary | `4785888` → `4f110cd` | Mac + Linux, `cbd7394` |
| P4.5 | Role invocation; strict answers; the scripted adapter | `d6319fd` → `6440ea5` | Mac + Linux, `cbd7394` |
| P4.6 | The transaction engine: basis, discovery, reproduction | `59d8517` → `cbd7394` | Mac + Linux, `cbd7394` |
| P4.7–P4.9 | Candidate tests, the challenge before the freeze (DG-07), the freeze | `be020cc` → `ef3c66b` | Mac + Linux, `30facae` |
| P4.10–P4.14 | One confined Implementer; verification; the challenge after it; independent review; compare-and-swap acceptance | `5fa1b15` → `0b8dbad` | Mac + Linux, `30facae` |
| P4.15 | A person's answer resumes or stops its own halt; Done or not, a person's only; the engine worker | `104fd2b` → `23e4bd5` | Mac + Linux, `d59aceb` |
| P4.16 | The task page: criteria → method → result → evidence, findings, review, not-known states, decisions | `1b86ee4` → `d59aceb` | as P4.15 |
| **P4.R1** | The first review's M1–M5 and L6–L11 (`docs/gates/P4.R1/dispositions.md`) | `8f4361c` → `b77bc81` | Mac `b77bc81` (862/556); with P4.R2 Mac + Linux `54966a4` |
| **P4.17** | End-to-end in a real browser (scripted roles); `lockstep serve` runs the engine worker with the helper's runner channel (Q5) | `8f4361c` → `b77bc81` | as P4.R1 |
| **P4.R2** | The second review's MEDIUM and LOW 2–6 | `1c52bb6` → `54966a4` | Mac + Linux `54966a4` (862/562) |

Every sub-phase: contract and tests frozen first with digests, a baseline failing for the defect's or the
not-built reason, then one writer implementing; no frozen test was changed except by the two owner-approved
amendments (A-P4.2-1, A-P4.3-1).

## 2. Scenarios (handoff update2 §5)

| Scenario | Evidence | Result |
|---|---|---|
| A bug from the browser through the real service, engine, Git, PostgreSQL and processes: frozen tests with a RED baseline, a challenge, one Implementer, verification of the exact commit, the challenge after it, review, the Supervisor's local commit, the evidence on the page and the person's Done; a recovery (uncommitted change) and a person's retry | `EndToEndTest` (C-P4.17 Q1, Q2) | PASS |
| An incorrect fix that passes the tests is rejected by an independent check (counterexample CONFIRMED), the second attempt accepted; a Reviewer's rejection; attempts and candidates bounded | `EngineImplementTest` (C-P4.10-14) | PASS |
| Cancellation, timeout, restart and database failure at consequential points: no role run again by itself (discovery, baseline, mutant, counterexample, review, implement), uncertain-and-halt atomic, the freeze once, a bounded stop, two engines on one database | `EngineRecoveryTest`, `EngineRecoveryTwoTest` (C-P4.R1, C-P4.R2) | PASS |
| Replay resistance: a replayed or older answer never resumes a later halt; only a person answers or decides | `EngineHumanTest` (C-P4.15) | PASS |
| The supported production arrangement: `lockstep serve` with the helper's runner channel starts a handed-over bug, takes it to its first role step, stops it for a person (no coding helper built in) and acts on their Stop; without a channel nothing starts | `ServeWorkerTest` (C-P4.17 Q5) | PASS |
| Protected test paths through the real container (real Docker) | `scripts/lib/check-runner-paths` | PASS 7/7 |
| The container runner's boundary (C-P4.2) | `scripts/lib/check-runner` | PASS (0 failures) |
| Snapshot memory bound: 384 MiB tree inside a 96 MiB heap | `lockstep-stress` | PASS (17 MB maximum residency) |
| Real-provider smoke | `docs/gates/P4.17/real-provider-smoke-proposal.md` | **PROPOSED, NOT RUN** — needs your authorization; the live adapter is NOT_BUILT |
| UX-C8, UX-C9 | — | **NOT_RUN — DEFERRED BY OWNER** |

The deterministic scenarios use scripted roles: they show the orchestration, boundaries and decision points;
they are **not evidence of real model coding capability**.

## 3. Independent reviews

1. `docs/reviews/phase-4-review-2026-10-28.md` (agent, read-only, `77a96ce..d59aceb`): no HIGH, five MEDIUM,
   six LOW — all dispositioned and fixed with regressions (C-P4.R1; L8, L9 and L11 reproduced first).
2. `docs/reviews/phase-4-remediation-review-2026-10-28.md` (agent, read-only, `cadd969..b77bc81`): no HIGH,
   one MEDIUM (the shutdown bound did not hold in the worst case; safety did), six LOW, four INFO — the MEDIUM
   and LOW 2–6 fixed with regressions (C-P4.R2); LOW 7 (a submodule's own filters) and the INFO items recorded
   with their dispositions. The R2 changes themselves have not had a third independent review.

## 4. What is not there, said plainly

- **No coding helper is built in.** The engine worker runs in the installed service only with the helper's
  runner channel, and without the live adapter each fix stops at its first role step for a person.
- **Turning the engine on in your installation is not done**: the `lockstep` launcher starts the helper
  without `--runner`. It is an installation step for you to authorize with the first real-provider trial.
- **Residuals**: a submodule's own configured filters are not switched off (operator-written configuration);
  migration 21's one-writer index cannot build on a database that already holds the race's duplicates (no
  such database exists); a Git LFS repository counts stat-changed files as changes (by design).
- **Known debt, deferred by you (2026-10-28)**: hand-written SQL instead of Orville's typed API and hand-built
  JSON instead of Fleece; Phase 4 finished in the existing style.

## 5. Decisions for the owner

1. Gate C-EXEC: accept / accept with exceptions / do not accept (candidate `54966a4`).
2. Separately: authorize the steps of the real-provider smoke proposal (build the live adapter, the egress
   proxy and credential handling; install; start the helper with `--runner`; one capped smoke).
3. Separately: UX-C8, UX-C9 when you choose.
4. Phase 5 is not started and will not be without your instruction.

## 6. Recommended disposition

**Accept with exceptions**, the exceptions being exactly: the real-provider smoke not run (owner-gated;
proposal ready); UX-C8/UX-C9 not run (deferred by you); the engine not yet on in your installation (with the
smoke); the residuals of §4; the R2 changes without a third independent review. Everything Phase 4 was asked
to build is built, frozen first, qualified on Mac and Linux, and reviewed twice.
