# Gate C-EXEC — decision packet

- For: the owner. Prepared 2026-10-28 by the writing agent (Implementer, manual). The Implementer cannot
  accept Gate C-EXEC; this packet recommends.
- **DRAFT — evidence still pending** (marked PENDING below): P4.17 and the independent review.
- Branch `phase-4` (from `77a96ce`). Authority: `.local/plans/phase-04.md` (`24db39d9…`) and
  `.local/plans/phase-04_update1.md` (`4cb620d3…`): DG-17 accepted; DG-06, DG-07 accepted with clarification;
  O-1 accepted; A-P4.3-1 approved. A-P4.2-1 approved in the session.
- **Qualified candidate: PENDING** (the P4.17 freeze and its full qualification).

## 1. What Phase 4 built, and its evidence

| Sub-phase | What | Frozen → implemented | Qualification |
|---|---|---|---|
| P4.1 | Allow Lockstep in a project (Bug Profile `lockstep-bug-fix` v1); hand over a ready task as a bug Work Order with no plan | `70b95d2` → `bd4512b` | Mac + Linux, `bd4512b` |
| P4.2 | Finite runners: direct process-group runner; the helper's container runner channel (`--runner`) | `b623d5d` → `ea9b445`, `b6385b6` (A-P4.2-1) | Mac + Linux, `b6385b6`; host container check 44/44 |
| P4.3 | Durable requests to a person and conversations; binding answers (person only, revision, once) | `ca44459` → `0fcb2b9`; A-P4.3-1 `4ee971d` | Mac + Linux, `4ee971d` |
| P4.4 | The Supervisor's Git boundary: clean basis, compare-and-swap work branch, Git-free snapshots, change checks, Supervisor commits | `4785888` → `4f110cd` | Mac + Linux, `cbd7394` |
| P4.5 | Role invocation: one path for every role; strict answers; the scripted adapter | `d6319fd` → `6440ea5` | Mac + Linux, `cbd7394` |
| P4.6 | The transaction engine: basis, discovery, reproduction; invocations recorded; cut-short runs never replayed; every halt a request to a person | `59d8517` → `cbd7394` | Mac + Linux, `cbd7394` |
| P4.7–P4.9 | Candidate tests (grounding, baseline), the challenge before the freeze (DG-07), the Supervisor's freeze | `be020cc` → `ef3c66b` | Mac + Linux, `30facae` |
| P4.10–P4.14 | One confined Implementer; verification of the exact commit; the challenge after it; independent review; compare-and-swap acceptance (no push) | `5fa1b15` → `0b8dbad` | Mac + Linux, `30facae` |
| P4.15 | A person's answer resumes or stops its own halt; Done or not, a person's only; restart-safe; the engine worker | `104fd2b` → `23e4bd5` | Mac + Linux, `d59aceb` (unit 862/862, integration 531/531) |
| P4.16 | The task page: where the fix stands, criteria → method → result → evidence, findings, review, not-known states; the person's decisions from the page | `1b86ee4` → `d59aceb` | as P4.15 |
| P4.17 | End-to-end in a real browser (scripted roles, no provider) | PENDING | PENDING |

Every sub-phase: the contract and tests frozen first with digests, a baseline failing for the not-built reason,
then one writer implementing; no frozen test was changed except by the two owner-approved amendments.

## 2. Scenarios

| Scenario | Evidence | Result |
|---|---|---|
| A bug fixed through the real UI, service, engine, Git and PostgreSQL, with a recovery and a person's decisions (C-P4.17 Q1) | `EndToEndTest` | PENDING |
| Real-provider smoke (finite, owner-authorized) | — | **NOT_RUN** — needs separate authorization; the live Claude adapter is **NOT_BUILT** |
| UX-C8 (Gate B browser walkthrough) | — | **NOT_RUN — DEFERRED BY OWNER** |
| UX-C9 (three-person novice usability) | — | **NOT_RUN — DEFERRED BY OWNER** |

The deterministic scenarios use scripted roles: they show the orchestration, boundaries and human decision
points work; they are **not evidence of real model coding capability** (handoff P4.17).

## 3. What is not there, said plainly

- **`lockstep serve` does not run the engine.** No coding helper is built into the binary (the live adapter is
  separately authorized), and the binary takes no test seams. In the end-to-end test the engine worker runs in
  the test's process against the same database. The installed service's pages keep saying that nothing runs
  yet, which stays true.
- **The engine has not been run with the container runner.** It is verified with the direct runner (no
  boundary, tests only); the container runner is verified on its own by C-P4.2's host check.
- **Independent read-only review of the Phase 4 code** (an agent, not a person; requested by the owner
  2026-10-28): PENDING.
- **Known debt, deferred by the owner (2026-10-28):** the persistence layer uses hand-written SQL rather than
  Orville's typed API, and JSON responses are built by hand rather than with Fleece encoders
  (`docs/reviews/simple-haskell-audit-2026-10-28.md`, `docs/reviews/fleece-audit-2026-10-28.md`); Phase 4 was
  finished in the existing style, to be fixed after the post-Phase-4 dogfooding.
- A start-up race in the folder helper (C-P3.5) was found by a full check and fixed (`30facae`).

## 4. Decisions for the owner

1. Gate C-EXEC: accept / accept with exceptions / do not accept (candidate PENDING).
2. Separately: authorize building the live Claude adapter and a finite real-provider smoke (cost and scope to
   be set by you).
3. Separately: installation on your Mac; UX-C8, UX-C9 when you choose.
4. Phase 5 is not started and will not be without your instruction.

## 5. Recommended disposition

PENDING the evidence above.
