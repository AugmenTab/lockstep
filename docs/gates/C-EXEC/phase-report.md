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
| P4.15 | **VERIFIED** at checkpoint `d59aceb` (frozen `104fd2b`): Mac and Linux clean clone, unit 862/862, integration 531/531 | `C-P4.15` | `docs/gates/P4.15/` |
| P4.16 | **VERIFIED** at checkpoint `d59aceb` (frozen `1b86ee4`): Mac and Linux clean clone, unit 862/862, integration 531/531 | `C-P4.16` | `docs/gates/P4.16/` |
| P4.R1 | **VERIFIED** at checkpoint `54966a4` (frozen `8f4361c`, implemented `b77bc81`): the review's M1–M5 fixed, L6–L11 fixed or reproduced and fixed (`docs/gates/P4.R1/dispositions.md`) | `C-P4.R1` | `docs/gates/P4.R1/` |
| P4.17 | **VERIFIED** at checkpoint `54966a4` (frozen `8f4361c`, implemented `b77bc81`): the end-to-end browser journey; `lockstep serve` runs the engine worker with the helper's runner channel (Q5). Real-provider smoke **PROPOSED, NOT RUN** (`docs/gates/P4.17/real-provider-smoke-proposal.md`) | `C-P4.17` | `docs/gates/P4.17/` |
| P4.R2 | **VERIFIED** at `54966a4` (frozen `1c52bb6`): the second review's MEDIUM and LOW 2–6. Checkpoint `54966a4`: Mac and Linux clean clone, unit 862/862, integration 562/562; host `check-runner` 0 failures, `check-runner-paths` 7/7; stress 17 MB | `C-P4.R2` | `docs/gates/P4.R2/` |
| P4.R3 | **VERIFIED** at checkpoint `d13ac33` (frozen `70ef870`, implemented `b0b922d`): the final P4.R2 review's MEDIUM (a stage belongs to the engine running it) | `C-P4.R3` | `docs/gates/P4.R3/` |
| P4.L | **VERIFIED offline** at `d13ac33` (frozen `a6b69e2`, implemented `c7a6d54`): the live Claude Code adapter, restricted egress, invocation-scoped credentials, the budget; unit 8/8, engine 7/7, host `check-live-runner` 84/84 against a stand-in upstream. **No provider contacted, nothing installed.** | `C-P4.L` | `docs/gates/P4.L/` |
| P4.L.R1 | **VERIFIED offline** at `d13ac33` (frozen `8d0790c`): the live-integration review's two MEDIUM and five LOW; `check-live-proxy` 20/20 | `C-P4.L.R1` | `docs/gates/P4.L.R1/` |

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
`.local/plans/phase-04_update2.md` (sha256 `c3b2a6fd…6278b8`): remediate M1–M5 and disposition L6–L11, then
P4.17, a supported production arrangement for the worker, and a smoke proposal (register entry "Phase 4
recovery and completion").

## Where it stands (2026-10-29)

P4.1–P4.17, P4.R1–P4.R3, P4.L and P4.L.R1 verified at `d13ac33` (Mac and Linux; the live path offline on the real
Docker host); four independent read-only reviews, every confirmed MEDIUM corrected with a regression check. The
revised decision packet (`decision-packet.md`) and the revised smoke proposal (`docs/gates/P4.L/`) are ready for the
owner. Nothing was installed, pushed or published; no real credential exists; no provider was invoked (the guard's
sentinel log is empty in every run; the live checks used a local stand-in); the operator's engine is not enabled;
no real coding transaction has run. Gate C-EXEC is not claimed; Phase 5 is not started.

`.local/plans/phase-04_update3.md` (sha256 `97c86589…2da6a12`): the final P4.R2 review, the offline live-provider
integration (B1–B3), the budget report, the revised smoke proposal (register entry "Phase 4 live-provider
integration, offline").
