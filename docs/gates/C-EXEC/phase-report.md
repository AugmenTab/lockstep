# Phase 4 report — first single-Engineer coding transaction (Gate C-EXEC)

- Authority: `.local/plans/phase-04.md` (sha256 `24db39d9…f5698`), owner instruction 2026-10-27;
  `DECISION_REGISTER.md` "Phase 4 authorization".
- Branch `phase-4` from `77a96ce` (Gate C-UX record). Production-code basis `fd5bb90`; the last
  qualified commit is `36cff9b` (Mac and Linux, unit 800/800, integration 422/422).
- Writer: one writing agent (Implementer, manual). No parallel writers.
- This report states what was actually done. A planned item is never reported as done.

## Status by sub-phase

| ID | Status | Contract | Record |
|---|---|---|---|
| P4.1 | **VERIFIED** at `bd4512b` (frozen `C-P4.1`; Mac unit 808/808, integration 446/446; Linux clean clone the same) | `C-P4.1` | `docs/gates/P4.1/` |
| P4.2 | **VERIFIED** at `b6385b6` (A-P4.2-1 approved): Mac and Linux, unit 831/831, integration 470/470; host container check 44/44 | `C-P4.2` | `docs/gates/P4.2/` |
| P4.3 | **VERIFIED** at `4ee971d` after A-P4.3-1 (approved 2026-10-28): Mac and Linux clean clone, unit 818/818, integration 454/454 | `C-P4.3` | `docs/gates/P4.3/` |
| P4.4 | **VERIFIED** (Mac `4f110cd`; checkpoint `cbd7394` Mac and Linux, unit 854/854, integration 500/500) | `C-P4.4` | `docs/gates/P4.4/` |
| P4.5 | **VERIFIED** at checkpoint `cbd7394` (Mac and Linux); the live Claude adapter NOT_BUILT (separately authorized) | `C-P4.5` | `docs/gates/P4.5/` |
| P4.6 | **VERIFIED** at `cbd7394` (Mac and Linux, unit 854/854, integration 500/500) | `C-P4.6` | `docs/gates/P4.6/` |
| P4.7–P4.9 | **VERIFIED** at checkpoint `30facae` (frozen `be020cc`): Mac and Linux clean clone, unit 862/862, integration 518/518 | `C-P4.7-9` | `docs/gates/P4.7-9/` |
| P4.10–P4.14 | **VERIFIED** at checkpoint `30facae` (frozen `5fa1b15`): Mac and Linux clean clone, unit 862/862, integration 518/518 | `C-P4.10-14` | `docs/gates/P4.10-14/` |
| P4.15 | **IMPLEMENTED** (frozen `104fd2b`; P4.15 group 7/7; every C-P4 group 103/103); full qualification at the next checkpoint | `C-P4.15` | `docs/gates/P4.15/` |
| P4.16–P4.17 | not started | — | — |

The first full check at `0b8dbad` failed one test of 518: a start-up race in the folder helper (C-P3.5), which
gave the pane its copy after placing the list the frozen test waits on. Fixed in the helper at `30facae` (the
order of the two writes only); the frozen test is unchanged.

## Known debt, deferred by the owner (2026-10-28)

Audits found that the persistence layer (all 15 modules, Phases 1–4) runs hand-written SQL strings through
Orville instead of Orville's typed API, and that every JSON response is built by hand instead of with Fleece
encoders (with an escaper that corrupts characters above U+FFFF). Reports:
`docs/reviews/simple-haskell-audit-2026-10-28.md`, `docs/reviews/fleece-audit-2026-10-28.md`. The owner's
decision: finish Phase 4 first, **in the existing style** (no mix of patterns: Orville's typed API and
schema registration are not set up); fix the whole layer after the post-Phase-4 dogfooding.

## Deferred human scenarios from Gate C-UX

| Scenario | Status |
|---|---|
| UX-C8 (Gate B browser walkthrough) | NOT_RUN — DEFERRED BY OWNER TO PHASE 4 |
| UX-C9 (three-person novice usability) | NOT_RUN — DEFERRED BY OWNER TO PHASE 4 |

Neither is run or represented by automation. Their protocols are unchanged (`docs/gates/C/`).

## Owner decisions

Decided in `.local/plans/phase-04_update1.md` (sha256 `4cb620d3…a6f1d7`): DG-17 accepted; DG-06 and DG-07
accepted with clarification; O-1 accepted; A-P4.3-1 approved (applied). A-P4.2-1 approved (applied).

## Where it stands (2026-10-28)

P4.1–P4.14 verified (Mac and Linux). P4.15 implemented; P4.16 next. Nothing was installed, pushed or published; no
provider was invoked (the guard's sentinel log is empty in every run). Gate C-EXEC is not claimed.
