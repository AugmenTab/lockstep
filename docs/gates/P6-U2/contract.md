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

## U2-B — R6.3 stale authority and cancellation, R6.4 floors, R6.5 usage, R6.6 proposals, DG-08 Phase signoff

| # | Decision |
|---|---|
| A1 | **Invalidation withdraws in the same transaction.** Recording an invalidation of a fix (`Invalidations.recordOnce`, C-P6.7 V2: rejection, a rejected or invalidated ancestor, a plan change) withdraws every open request about that fix as the Supervisor (C-P4.3 H2 `Withdraw`), one `withdrawal` message each, beginning `Invalidated (<code>)`. Nothing is deleted. A late answer is refused `request-closed` and changes nothing; a repeat withdraws nothing. |
| A2 | **A newer halt supersedes.** When the engine opens the request for a fix's current halt, any older open request about the same fix is withdrawn as `Superseded (<code>)`, so a request an older database left open is closed by the next pass and never revived by a restart. |
| A3 | **Where a request stands** (pure `Kernel.Inbox.requestStanding`): `current` (open, its fix halted on it, the fix counts), `superseded`, `resolved` (answered and acted on: a `resume` or `cancellation` record names it), `answered-not-acted` (the effect not taken yet), `invalidated`, `withdrawn`. `Inbox.requestsOfTask` lists every request of a task's hand-overs with its standing; the Decisions page lists the 30 most recently closed under **Earlier requests**, links only. |
| A4 | **Cancel stops first** (update 1 §5). `Cancellation.requestCancel`: no live fix → canceled now (as before); a fix handed over, running or halted → the cancel is recorded (migration 32, one per fix, replay-safe) and the task is not canceled yet; an accepted fix → `fix-accepted` (decide Done or Not done first). The engine applies the person's cancel as their Stop at the next safe point (between stages; a `cancellation` record, the fix's open requests withdrawn in the same transaction), except on a halt for an uncertain helper outcome, which waits for the person's own decision. `settleCancellations` (each worker pass) cancels the task once its fix has stopped, or records `not-canceled` when it was accepted or Done first. `decideTask … CancelTask` is unchanged (`fix-active`, C-P6.5 S10); the task page's Cancel uses the new path and shows where it stands. |
| F1 | **Floors by value** (`WorkPolicy.floorStandings`, `missingChecks`): each floor check of the kind is held `as-required` or `stronger` (the same id and stage, every axis at least as strong, no exception path: the Profile kernel's own `checkStronger`), else it is `weaker`, `incomparable` (another stage) or `missing`, and the hand-over is refused. The named Profile's checks are held by the repository's the same way (`profile-checks-missing` otherwise). |
| F2 | **Effective checks shown** (`EffectiveChecks.effectiveChecksOf`, the task page's "Checks this work runs under"): the Profile and version the Work Order is bound to, the kind, each floor check's standing, exceptions (none is stored for a Work Order, so none applies), non-behavioural, budgets. A later Profile version binds nothing already handed over. `lockstep-engineering` stays off the checks page's choice list (frozen C-P3.7 `ProjectChecksTest`); it shows on the task page and the Plan page's offer. |
| U1 | **Usage standing** (pure `Kernel.Summary.usageStanding`): `no-invocation` (no role run), `complete` (every run reported every class and Lockstep kept its whole output), `partial` (the known counts only; a missing class unknown, never zero; a run kept only as its tail never complete), `unavailable` (runs, none reporting). Each run's evidence (`complete`, `partial`, `truncated`, `missing`) is listed with its recorded invocation (`summaryUsageRuns`). `summaryUsage` keeps C-P6.8's meaning (the known counts); the Progress page adds the standing in words. No cost is inferred. |
| Q1 | **Proposal evidence** (OQ-P6.9-1, A-U2-2, A-U2-3): `commit:` evidence must be a commit a Lockstep fix recorded (basis, freeze, candidate or accepted), in its lower-case spelling, else `evidence-unknown`. A Profile rule targets a catalog Profile at its latest version, or version 1 of Lockstep's own not yet in the catalog; else `unknown-target` / `stale-target`. |
| Q2 | **Stale rejection** (OQ-P6.9-2): a stale proposal may be rejected (terminal, writes only the decision); approving it stays `stale-target`. |
| G1 | **DG-08 Phase signoff, option C with B by default.** A human gate is a human-acceptance edge from a unit of one phase to a unit of another (`Kernel.PhaseGate.humanGates`): part of the approved, digest-bound plan. The scheduler never passes it without the person's Done (C-P6.5 S1); every other boundary advances provisionally. A Planner-proposed revision that removes or weakens a gate of the revision in effect is refused `human-gate-removed` (`gatesRemoved`); the owner's own revision may change it. `PhaseGates.phaseGatesOf` shows each gate `waiting-for-signoff` or `signed-off`. No `PlanDocument` field was added (it would break the frozen fixtures that construct it). |

### Mandatory tests (handoff §4.3, §5, §6, §7, §8.1) → cases

| Handoff test | Where |
|---|---|
| R6.3 reject an ancestor: dependent requests lose authority; a stale approval cannot resume; an unrelated request stays; history kept; idempotent; a fresh identity; restart/replay | integration `rejectionWithdraws`; unit `requestStanding`, `withdrawalText` |
| R6.3 older database: restart and replay do not resurrect stale authority | integration `legacyOpenSuperseded` |
| R6.3 live fix not hidden by cancellation; safe boundary before settlement; uncertain effect not discarded | integration `cancelHalted`, `cancelBeforeStart`, `cancelUncertain`, `cancelAccepted` |
| R6.3 the UI distinguishes current, superseded, resolved, invalidated, uncertain | unit (the Decisions page renders "Earlier requests" with each standing's words) |
| R6.4 engineering Profile shown; floors displayed accurately | integration `engineeringShown`, `strongerAccepted` |
| R6.4 weaker, missing floor refused; stronger accepted; an exception cannot lower; stale Profile revision | integration `weakerRefused`, `strongerAccepted`, `staleVersion`; unit `floorStandings` |
| R6.5 truncated never complete; exact total; missing cache-read unknown; no-run vs zero; invalidated keeps usage; linked sources | integration `complete`, `partial`, `truncated`, `noRunAndZero`, `invalidatedKeeps`; unit `usageStanding`, `runEvidence` |
| R6.6 unverifiable evidence, unsupported target; no self-approval | integration `commitRecorded`, `knownTarget`, `staleRejection`; C-P6.9 `forged`, `noAutoInstall`, `selfPrivilege` (amended) |
| DG-08 C/B | integration `gateHolds`, `plannerCannotRemove`; unit `humanGates`, `gatesRemoved` |

### Freeze record (U2-B)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/RequestStandingTest.hs` | `7f65f1e11e3fd5109369a97b32fb7804e2ab61e00929725d92cdf18da150f765` |
| `test/unit/Lockstep/Kernel/FloorStrengthTest.hs` | `7969c55155e9776f68ebcb6f47edb74a80612ed0d075d5ab07263cd48ae60815` |
| `test/unit/Lockstep/Kernel/UsageEvidenceTest.hs` | `9ad96896b8216ecfbb1cd5f90ab084f16f188b887b48e551b2de4aebf3b225b0` |
| `test/unit/Lockstep/Kernel/PhaseGateTest.hs` | `16a20d1dc90e4f92866cd6892fa8c54dfc9f566e9e9e7b671b0fc849ff1de33d` |
| `test/integration/Lockstep/StaleAuthorityTest.hs` | `686f38b42f6476d4f8395f31ef7dcfa4d10d69da3971cd7dc27b842e98d3c897` |
| `test/integration/Lockstep/ProfileFloorTest.hs` | `3ec392c0368f11dc610f8494b86796425919b3efeefb66cb32fb6e151f0ade42` |
| `test/integration/Lockstep/UsageEvidenceTest.hs` | `15b5e01d7f72b8066e6fe44fcf98dd853f671fa451c621dffe87edeb10717983` |
| `test/integration/Lockstep/ProposalIntegrityTest.hs` | `77551111eeabe5dd236b8bf62b68fafbec4004fa26c0e349ce61581fbf035ec8` |
| `test/integration/Lockstep/PhaseGateTest.hs` | `4d35384148c38c30fb5c0111abebdb52e06cfcfcf1cd5d2527b8118054a4bf0a` |
| `test/integration/Lockstep/ProposalTest.hs` (A-U2-2 applied) | `6a66504475dd7e2fca075633ae9bd459e3d8936875dbce8f52b3c2cdab2b8301` |
| `test/integration/Lockstep/ProposalReviewTest.hs` (A-U2-3 applied) | `12dbebfda3ca6e6946c097b24fdbdd51b10e2fec8b1f7a2d4565c8b6f779493a` |
| `test/integration/Main.hs` (shared runner, additive) | `08250a53c73c619fa847b45800a49080a0212c6d6ed2223c266a111d10551eca` |
| `test/unit/Main.hs` (shared runner, additive) | `b5e5e297e187151c04a9ce043843afe3ed2d739fa010cf7cc6599d439e404351` |

Formatted and linted before the digests were taken. RED baseline against stubs (`Kernel.Inbox` standing, `Application.Inbox`
history, the Decisions page's third argument ignored, `Application.Cancellation`, `WorkPolicy.floorStandings`,
`Application.EffectiveChecks`, `Kernel.Summary` standing, the summary's two new fields constant, `Kernel.PhaseGate`,
`Application.PhaseGates`), with Engine, Invalidations, Conversation, EngineWorker, Execution, Plans, Proposals and the
Progress page at `aa28633`; logs `.local/evals/phase-06/u2b-red-{unit,integration}.log`:

- Unit: **23 of 27 new cases fail**. The four that pass are guards the stubs happen to meet (an exception path is already
  refused by C-P6.6's exact comparison; "unavailable" and "nothing removed" are the stubs' constants).
- Integration: **19 of 32 fail**, each at its missing behaviour (an invalidated fix's request still open; a legacy open
  request not superseded; cancel `not-implemented`; a stronger floor refused; no effective checks; usage standing
  missing; an unrecorded commit and an unknown target accepted; a stale rejection refused; no gates; a Planner draft that
  removes a gate proposed). Passing guards: the weaker-floor refusals and the 12 amended C-P6.9/R-P6.9 cases (they hold
  before and after).

**Disclosed:** the trial against the implementation (`u2b-trial-*.log`: unit 1110/1110; 159 of 161 integration cases
across U2 and C-P6/R-P6) found one wrong expectation, in the unit test only: an invalidated fix's own Stop-only
request is the current one, not invalidated. `RequestStandingTest`'s second case was corrected before the digests
above (it still fails against the stub, which answers `withdrawn`), and the Kernel rule orders "halted on it" first.
After that, `u2b-trial2-*.log`: unit passed, R6.3 integration 6/6. A naming clash found while building
(`standingWords`) was renamed in the implementation only.

### Allowed paths (U2-B)

New: the freeze files above, `Persistence/Cancellations.hs`, `Application/{Cancellation,EffectiveChecks,PhaseGates}.hs`,
`Kernel/PhaseGate.hs`. Changed: `Kernel/{Inbox,WorkPolicy,Summary,Transaction,Task,Profile}.hs` (Profile: export
`checkStronger` only), `Persistence/{Migrations,Conversation,Execution,Transactions}.hs` (migration 32 appended),
`Application/{Inbox,Conversation,Invalidations,Engine,EngineWorker,Execution,Plans,Proposals,Summary}.hs`,
`Web/{App,DecisionPages,ExecutionPages,ProgressPage}.hs`, the runners, `docs/OPERATOR_GUIDE.md`. Rollback: the branch;
migration 32 is additive.
