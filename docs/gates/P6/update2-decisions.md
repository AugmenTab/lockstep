# Phase 6 update 2 — owner decisions recorded

- Authority: `.local/plans/phase-06_update2.md` (owner-authorized handoff).
- Recorded: 2026-11-15, by the Implementer, from the owner's answers in the working session that began Update 2.
  The Implementer decided none of these.

| Id | Question | Owner's decision |
|---|---|---|
| A-U2-1 | R6.2: the frozen C-P6.4 `PlanTest.parity` case hands the greenfield unit `core` (its fixture names `lockstep-bug-fix`) over through `admitBug` with bug-only checks, and expects it accepted as a bug fix. That pins the defect R6.2 fixes. | **Authorized.** Amend only `parity`: `core` names `lockstep-engineering`, the engineering checks are chosen after enabling, both hand-overs are still accepted, and `core` is admitted as greenfield. All other assertions are kept; the old and new digests are recorded (`docs/gates/P6/update2-amendments.md`). |
| OQ-P6.9-1 | May the frozen C-P6.9 tests be amended so that (a) the shared fixture cites a commit a fix recorded, letting `commit:` evidence require a recorded commit, and (b) `selfPrivilege` registers `team-checks`, letting a proposal for a non-catalog Profile be refused `unknown-target`? | **Authorized** (both). |
| OQ-P6.9-2 | May a proposal whose target has moved on still be *rejected*? | **Allowed** with the handoff's §7.3 semantics: a stale, still-pending proposal may be rejected as a terminal, non-authorizing disposition. It cannot overwrite a newer decision or affect an adopted version. Approving a stale proposal stays forbidden. |
| DG-08 Phase signoff | Which rule governs crossing a local phase boundary inside an approved plan? | **Option C, with B as the default.** A human Phase signoff is needed only where the approved plan explicitly designates a human gate. Elsewhere, provisional technical advancement continues inside the approved plan authority, and Human Done and consequential approvals stay independent. The plan must be able to express the gated boundaries; a Planner refinement can never remove a gate; enabling automatic scheduling never waives one. DG-08's accepted plan-freeze architecture is not reopened. |
