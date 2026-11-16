# Contract — Phase 6 update 2: execution correctness and governance closure

- Contract ID: `C-U2@v1`
- Status: FROZEN in increments (each section's freeze record below).
- Authority: `.local/plans/phase-06_update2.md` (R6.1–R6.6, §8); owner decisions recorded in
  `docs/gates/P6/update2-decisions.md` (A-U2-1, OQ-P6.9-1, OQ-P6.9-2, DG-08 Phase signoff).
- Basis: `phase-6` at `2dd48b2` (the update-1 return packet; the latest full check passed at `6b0a6c6`: unit 1078,
  integration 699, backup/restore).
- Writer: the single writing agent (Implementer). The Implementer accepts nothing.
- Preserved: D6-AUTH provisional progression, DG-08 immutable approved revisions, DG-05 effective Profile constraints,
  DG-04 effect identity/fencing/replay, the single-writer repository model, Git and human authority boundaries.

## Baseline inspection (handoff §1)

| Carried limitation | Inspected in the code at `2dd48b2` | Still present |
|---|---|---|
| P6.5: a prerequisite reached only by an untyped dependency builds on the person's checkout | `Tasks.basisCandidates` took a candidate only for a `Technical` plan edge; every other satisfied prerequisite (untyped, or a human-acceptance/external edge satisfied by Done) gave no commit, and the basis stage fell back to `observeBasis` (the checkout's `HEAD`) | yes — and wider than recorded: typed non-technical edges too |
| P6.7: a person's first hand-over of a plan unit runs as a bug fix | `Execution.admitBug` used `personOptions` (`BugFix`, no Profile) when the task had no earlier admission; frozen C-P6.4 `PlanTest.parity` pinned it | yes |
| P6.7: older halt requests stay open after an invalidation | `Invalidations.recordOnce` wrote only the invalidation; the engine's next pass halted the fix again and opened a Stop-only request, leaving the earlier request `open` | yes (U2-B) |
| P6.6: `lockstep-engineering` not on the checks page list; floors checked "for presence" | see U2-C | see U2-C |
| P6.8: usage read from a 2000-character tail | see U2-C | see U2-C |
| P6.9: commit evidence checked for form only; non-catalog Profile targets undecidable | see U2-C | see U2-C |

## U2-A — R6.1 authoritative basis, R6.2 first-unit Profile

| # | Decision |
|---|---|
| B1 | **One compatibility rule for every dependency** (pure `Kernel.Dispatch.basisCommits`). Whatever reached a prerequisite — a technical edge, a human-acceptance or external edge, or an untyped task dependency recorded the older way — the same rules apply, refusals in this order: every prerequisite still satisfied (S1) else `prerequisite-unsatisfied`; a prerequisite whose latest fix's acceptance no longer counts gives no basis even when its Ticket says done, `prerequisite-invalidated`; a fix that is accepted or Done gives its accepted commit, one without it `prerequisite-basis-unrecorded`; a prerequisite satisfied without a Lockstep commit (its Ticket closed through delivery) refuses a **planned** unit (`prerequisite-basis-unrecorded`: a plan unit builds on recorded results only) and gives nothing to standalone work. |
| B2 | **Never the checkout when a predecessor result exists.** A fix with predecessor commits is built on the one that contains all the others (C-P6.5 S8, `basis-ambiguous` otherwise: Lockstep merges nothing). The checkout's `HEAD` is the basis only for work with no predecessor result — standalone work (C-P4.1), whose authority is the canonical repository the Engineer owns (ownership, clean worktree, a commit). |
| B3 | **Checked at the hand-over and at the basis.** The hand-over (a person's or the scheduler's) refuses with B1's code, or `prerequisite-basis-missing` when a predecessor's accepted commit is not a commit of the repository; the scheduler records the refusal once and shows it (`refused`), and tries again each pass. The basis stage checks again before building (`prerequisite-basis-missing` halts it, never the checkout). Provenance rows (`lockstep_fix_bases`) are written with the basis, as before, for every edge kind. |
| B4 | **Restart and replay.** The basis is decided once, recorded with its provenance in one database transaction (R-P6.5-10); a restart or later passes never decide it again. |
| P1 | **The governed unit sets the kind and Profile.** A unit of the project's effective plan is handed over as the kind its approved unit names, under the Profile it names, whoever starts it and whether it is the first hand-over or a rework — exactly the scheduler's hand-over. A task outside the effective plan keeps the kind it was last handed over with; a plain task is a bug fix. An unreadable stored kind refuses `unknown-work-kind`. |
| P2 | **No substitution.** Checks that do not cover the unit's kind refuse the person's hand-over with the same code as the scheduler's (`kind-checks-missing`, `profile-too-weak`, `profile-checks-missing`, `profile-unknown`), never a bug fix instead. RED/GREEN, verification and review obligations are the kind's own (C-P6.6 G1); none is weakened. |

### Mandatory tests (handoff §2.3, §3.3) → cases

| Handoff test | Where |
|---|---|
| R6.1-1 planned unit uses the predecessor's accepted commit | integration `plannedBasis` |
| R6.1-2 legacy dependency cannot select the checkout | integration `legacyAndTypedBases` (untyped part) |
| R6.1-3 typed and legacy resolve consistently | integration `legacyAndTypedBases` (human-acceptance edge part); unit `basisCommits` |
| R6.1-4 stale or missing predecessor basis refuses | integration `missingBasisRefused`; unit (unrecorded, invalidated) |
| R6.1-5 competing writer prevents dispatch | integration `writerAndStandalone` (guard) |
| R6.1-6 unrelated repository unaffected | integration `writerAndStandalone` (guard) |
| R6.1-7 standalone bug fix without a plan | integration `writerAndStandalone` (guard) |
| R6.1-8 restart and replay keep the basis | integration `plannedBasis` (guard) |
| R6.1-9 rejected ancestor leaves nothing eligible | integration `rejectedAncestor` (guard); unit (invalidated beats a done Ticket) |
| R6.2 human first, scheduler second, both greenfield | integration `greenfieldFirstByPerson` |
| R6.2 brownfield bug fix stays a bug fix | integration `substitutionRefused` (plain task) |
| R6.2 planned feature uses its Profile | integration `plannedKinds` |
| R6.2 unauthorized substitution refused | integration `substitutionRefused` |
| R6.2 bound across restart and retry | integration `plannedKinds` (replay, fresh runtime) |
| R6.2 obligations not disabled by misclassification | integration `plannedKinds` (documentation keeps non-behavioural `docs`); `greenfieldFirstByPerson` |

### Freeze record (U2-A)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/BasisAuthorityTest.hs` | `8b08edd9aaa788a3f2cc7d42caa40f4e1fd4bf355171b654e2dc8f7a1721a823` |
| `test/integration/Lockstep/AuthoritativeBasisTest.hs` | `13931dbfe80df958ae3ec3739d79e495037d6e3fecdaca49532ac70a14a69894` |
| `test/integration/Lockstep/PlanProfileTest.hs` | `b3abedf38c3fc63e4f59d751d5a3af37e2fed007d351cbf454c035c7f9e6b1d7` |
| `test/integration/Lockstep/Support/Scheduling.hs` (new shared fixtures) | `cf9360d841935bf3622554f53b212f6431ee626c5eb13b059c69da185d57905e` |
| `test/integration/Lockstep/PlanTest.hs` (A-U2-1 applied) | `4212d49da487ab2e5ac4a02dfae91b6194f90a97f90f72c3c45b7a3084b759c7` |
| `test/integration/Main.hs` (shared runner, additive) | `6b8379934ef0714d17a901859dbf9a44273ccacaa2a5c01fc781f473b34c2873` |
| `test/unit/Main.hs` (shared runner, additive) | `13aae9ae58b50778d37659717936bc911726d37eb663c1a6a0249af021fafc43` |

Formatted and linted before the digests were taken. RED baseline against the stub (`basisCommits` returning
`not-implemented`; nothing else changed), logs `.local/evals/phase-06/u2a-red-{unit,integration}.log`:

- Unit: **6 of 6 fail** at the stub.
- Integration: **6 of 9 fail**, each at its own missing behaviour: `parity` (A-U2-1) admits `core` as a bug fix
  (greenfield count 0); the untyped dependent's basis is the checkout, not the predecessor's commit; a predecessor
  commit that is gone is handed over; the three R6.2 cases admit the person's plan unit as a bug fix.
- Kept as guards (they pass): `plannedBasis`, `rejectedAncestor`, `writerAndStandalone`.

The implementation trial (`u2a-trial-*.log`) passed the whole unit suite (1084) and 62 integration cases (U2-A, C-P6.4
through R-P6.7) with no test changed after the baseline.

## Allowed paths (U2-A)

New: the §freeze files, `docs/gates/P6-U2/**`, `docs/gates/P6/update2-*.md`. Changed: `Kernel/Dispatch.hs`,
`Application/Tasks.hs`, `Application/Execution.hs`, `Application/Engine.hs`, the runners, `PlanTest.hs` (A-U2-1 only).

## Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free (scripted roles). Rollback: the branch; no migration in U2-A.
