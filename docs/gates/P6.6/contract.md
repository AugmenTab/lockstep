# Contract — P6.6 Greenfield and brownfield Profile parity

- Contract ID: `C-P6.6@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06.md` §11 (P6.6); `.local/plans/phase-06_update1.md` §7.
- Basis: `phase-6` after C-P6.5 qualified (`1753832`).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

C-P6.4 plans already name each unit's **work kind** (`bug-fix`, `feature`, `greenfield`, `refactor`, `documentation`)
and a **Profile**. Proposal rules refuse a bug fix in a greenfield plan and a greenfield build in a brownfield one.
Nothing reads either name when work starts. Every hand-over (C-P4.1, and C-P6.5's scheduler) is an engineering Work
Order classed `bug` under the repository's default Profile. The engine's rules are the bug fix's: a test expected to
fail at the basis is always required. P6.6 binds each kind to an explicit, testable set of checks and to its
legitimate test-first behaviour, in the **same** engine. No universal invariant is weakened and no budget is
configurable.

| # | Decision |
|---|---|
| G1 | **Work policy** (pure `Lockstep.Kernel.WorkPolicy.workPolicy`), one per kind: its class tag (`bug`, `feature`, `greenfield`, `refactor`, `documentation`); its test-first rule; whether a reproduction is expected; whether it is non-behavioural; and its budgets. **Red first** applies to bug fixes, features and greenfield builds: at least one frozen test fails at the basis for its stated reason (what is asked is not there yet). **Green only** applies to refactors and documentation: every frozen test passes at the basis and must still pass, and a test made to fail is never accepted. No false RED is manufactured. A reproduction is expected only for red-first kinds. Only documentation is non-behavioural. The budgets (2 correction rounds, 2 Implementer attempts) are the engine's own constants for every kind: nothing in a plan or a Profile sets them. |
| G2 | **Floors** (`kindFloor`): the checks every Profile used for a kind must hold unchanged, all before acceptance and approved by the Supervisor unless noted. **Bug fix:** the five `lockstep-bug-fix` checks, unchanged. **Feature:** `feature-requirements` (requirements basis), `feature-tests` (frozen tests), `feature-verification` (verification record), `feature-review` (independent review). **Greenfield:** `greenfield-requirements` (requirements basis and architecture assessment), then `greenfield-tests`, `greenfield-verification`, `greenfield-review`. **Refactor:** `refactor-authorization` (human approval record, approved by a person: the owner's plan approval), `refactor-characterization` (frozen tests), `refactor-verification` (regression evidence and verification record), `refactor-review`. **Documentation:** `documentation-classification` (classification rationale), `documentation-verification`, `documentation-review`. No check that freezes tests has an exception path, so no exception can turn tests off. Every floor has an independent review. |
| G3 | **Built-in Profile `lockstep-engineering`** v1: every floor's checks (the bug checks identical to `lockstep-bug-fix`'s), allowing non-behavioural work. Switching a project from `lockstep-bug-fix` to it loses no check. It is registered when the owner chooses it, as `lockstep-basic` is. The Plan page offers that choice when the plan in effect has units the project's checks do not cover. Plans may name it. |
| G4 | **Precedence and binding at the hand-over** (`admitTask`, with the unit's kind and named Profile; a plain task is a bug fix as before). Kind floor ≤ the unit's named Profile ≤ the repository's Profile. (a) The repository's current Profile, resolved for the kind's facts, holds the floor unchanged; otherwise `bug-checks-missing` for a bug fix (as before) or `kind-checks-missing`. (b) The unit's named Profile (latest in the catalog, or built in), resolved the same way, holds the floor; otherwise `profile-too-weak`. (c) The repository's resolved checks hold every check of the named Profile's resolution; otherwise `profile-checks-missing`. The Work Order's binding and digest stay C-P2.5's, from the repository's Profile. The Work Order is classed by the kind's class tag; a documentation Work Order is non-behavioural with the path class `docs`. The admission records the kind (migration 28). A Profile change after the hand-over does not change a bound Work Order. |
| G5 | **One engine.** Every kind runs the same transaction engine and stages; only the policy differs. (a) A discovery that names a reproduction for a kind that expects none halts at discovery (`role-failed reproduction-not-expected`). (b) A green-only kind's candidate tests are judged by the Kernel input `CandidateCharacterized`. All green at the basis goes on; a red test, or a green test that fails, is a correction round within the same budget; a run failure halts `baseline-run-failed`; exhaustion halts `candidates-exhausted`. (c) Before a documentation fix is accepted, every path its implementation changed (freeze → candidate) must be documentation (`pathClassOf`); otherwise it halts `supervisor-failed behaviour-in-documentation`. A behavioural change is never accepted as non-behavioural. (d) Everything else is C-P4's: the reproduction, if any, is RED at the basis; there is always an independent review and Supervisor acceptance; there is never a push or a Done. |
| G6 | **Classification.** C-P6.4's proposal rules stand (`incompatible-mode`). A unit whose named Profile does not hold its kind's floor is refused at the hand-over (G4 b), recorded and shown as `refused` (C-P6.5 R-P6.5-6). A documentation unit that changes behaviour is refused at acceptance (G5 c). |

## 2. Typing

- Kernel: `Lockstep.Kernel.WorkPolicy`: `TestFirst`, `WorkPolicy`, `workPolicy`, `kindClass`, `kindFloor`,
  `engineeringProfileId`, `engineeringRaw`, `engineeringDefinition`, `missingChecks`, `pathClassOf`,
  `documentationOnly`. `Lockstep.Kernel.Transaction`: the `CandidateCharacterized` input.
- Persistence: migration 28 adds `work_kind` to `lockstep_bug_admissions` (default `bug-fix`); `AdmissionFacts` reads it.
- Application: `Execution.admitTask` (`AdmitOptions` gains the kind and the named Profile), `Dispatch` (passes the
  unit's), `Engine` (discovery, candidate, accept), `ProjectChecks` (registers `lockstep-engineering` when chosen),
  `Plans.knownProfiles`.
- Web: the Plan page's offer of `lockstep-engineering`.

## 3. Mandatory tests (handoff §11) → cases

| Handoff test | Where |
|---|---|
| Profile precedence and digest binding | integration `featureRuns` (the Work Order's digest is the repository Profile's, classed `feature`); `namedProfileTooWeak`, `repositoryLacksKind` |
| Invalid weakening refused | unit (`missingChecks`: a weakened check counts as missing); integration `namedProfileTooWeak` |
| Required tests cannot be disabled through an exception | unit (no floor check that freezes tests has an exception path) |
| Profile changes cannot bypass independent review | unit (every floor has an independent review, and `lockstep-engineering` holds them); integration `repositoryLacksKind` |
| Incorrect greenfield/brownfield classification rejected | integration `classification` (`incompatible-mode`; `behaviour-in-documentation`; `reproduction-not-expected`) |
| Different source modes invoke the same core engine | integration `featureRuns`, `greenfieldRuns`, `refactorRuns`, `documentationRuns` (the same engine passes) |
| No silent removal of implementation budgets | unit (every kind's budgets are the engine's constants); unit (`CandidateCharacterized` corrections are bounded) |

## 4. Verification files

`test/unit/Lockstep/Kernel/WorkPolicyTest.hs`, `test/integration/Lockstep/ProfileParityTest.hs`, and the two runners.

## 5. Freeze record

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/WorkPolicyTest.hs` | `1e00d9f7f6223b3ba67d214c10afb10f9133b0f709188c10392c632e6eb60678` |
| `test/integration/Lockstep/ProfileParityTest.hs` | `c92a5ac5bdd3b264603c1e18fb15a8efbdf8d95e72a1cbd78c3b8e0b853a5887` |
| `test/integration/Main.hs` (shared runner; supersedes R-P6.5's digest, additive) | `dba6aaada70058fa281ea82f6b44e4ce9915eb591047d19c812e82cf645b7218` |
| `test/unit/Main.hs` (shared runner; supersedes C-P6.5's digest, additive) | `ccb1c6129931d68aa1c95770dbb6869999813b2daca221e19c74b89e41bfa98e` |

The tests were formatted and linted before the digests were taken; lint's one hint, a lambda, was fixed first.

**RED baseline against the stubs.** The stubs are `Kernel.WorkPolicy`, plus the `CandidateCharacterized` input
with no transition, so it is illegal. Nothing else changed.
- Unit: **18 of 22 fail**. The four that pass are true of the stub's constants: one class tag for every kind, the
  vacuous floor checks, no exception path, and the input being illegal outside the candidate stage.
- Integration: **7 of 7 fail**, all at the first piece missing, G3. `lockstep-engineering` is not registered when
  chosen (`profile-unknown`) and not known to plans (`unknown-profile`).
- Logs: `.local/evals/phase-06/p66-baseline-unit.log` and `p66-baseline-integration.log`.

**Disclosed:** because every integration case stopped at G3, the frozen tests were first run against the
implementation in the working tree (unit 22/22, integration 7/7, `.local/evals/phase-06/p66-pretrial-*.log`). This
was done so that a fixture mistake would not be frozen. None was found, and no test changed. The implementation
was then set aside, the stub tree restored, and the baseline above run again on it before this freeze.

## 6. Allowed paths

New: §2/§4 files, `docs/gates/P6.6/**`. Changed: `Kernel/Transaction.hs`, `Persistence/Migrations.hs` (append 28),
`Persistence/Transactions.hs`, `Persistence/Execution.hs`, `Application/Execution.hs`, `Application/Dispatch.hs`,
`Application/Engine.hs`, `Application/ProjectChecks.hs`, `Application/Plans.hs`, `Web/PlanPage.hs`, `Web/App.hs`, the
runners, `docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free (scripted roles). Rollback: the branch; migration 28 is additive.
