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
| P4.2 | **BLOCKED — waiting for DG-17** (owner) | — | `design-gates-decision-request.md` |
| P4.3 | **IMPLEMENTED, qualification blocked on A-P4.3-1** (owner): frozen runner import order fails the format step; with the amendment trialled, unit 818/818 and integration 454/454 on the Mac; frozen bytes restored | `C-P4.3` | `docs/gates/P4.3/` |
| P4.4 | blocked behind P4.2 | — | — |
| P4.5 | **BLOCKED — waiting for DG-17** | — | — |
| P4.6 | blocked behind P4.5 | — | — |
| P4.7 | **BLOCKED — waiting for DG-07** (and P4.5–P4.6) | — | — |
| P4.8 | **BLOCKED — waiting for DG-06** (and P4.4–P4.7) | — | — |
| P4.9–P4.17 | blocked behind the above (P4.10 also on DG-17) | — | — |

## Deferred human scenarios from Gate C-UX

| Scenario | Status |
|---|---|
| UX-C8 (Gate B browser walkthrough) | NOT_RUN — DEFERRED BY OWNER TO PHASE 4 |
| UX-C9 (three-person novice usability) | NOT_RUN — DEFERRED BY OWNER TO PHASE 4 |

Neither is run or represented by automation. Their protocols are unchanged (`docs/gates/C/`).

## Open owner decisions

1. DG-06, DG-07, DG-17 — `design-gates-decision-request.md` (recommended options and the minimum
   decision for each). **Every remaining sub-phase waits on these**: P4.2, P4.5, P4.10 on DG-17; P4.7 on
   DG-07; P4.8 on DG-06; P4.4, P4.6, P4.9 and P4.11–P4.17 follow from them.
2. O-1 there: the built-in Bug Profile content (`lockstep-bug-fix` v1), built in P4.1.
3. A-P4.3-1 — `docs/gates/P4.3/amendment-request-1.md`: move one import line in the frozen unit runner
   (fourmolu order); digests before and after given; trialled green; not applied.

## Where it stopped (2026-10-28)

P4.1 verified (Mac and Linux, `bd4512b`). P4.3 implemented on `phase-4`; its qualification waits for A-P4.3-1.
No further sub-phase can be frozen without DG-06/07/17. Nothing was installed, pushed or published; no
provider was invoked (the guard's sentinel log is empty in every run). Gate C-EXEC is not claimed.
