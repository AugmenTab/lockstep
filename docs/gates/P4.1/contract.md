# Contract — P4.1 A project Lockstep may work in, and a bug handed to it

- Contract ID: `C-P4.1@v1`
- Status: **FROZEN** (2026-10-27; §4)
- Authority: Phase 4 handoff P4.1 ("Provide an execution-capable repository-bound Engineer and admit
  one no-plan bug Ticket under the effective Bug Profile. Prove that an organized project is not
  automatically authorized to execute, that repository ownership is valid and exclusive, and that no
  fictitious PhaseId or Master Plan is required"; exit "A real project and bug Ticket can be admitted
  through the existing application boundary, with correct policy and ownership"); Plan v0.3 §5 P4.1
  ("No PhaseId, valid ownership, one author"); Bible v2.2 §31.1 (Bug fix profile), Milestone C
  ("Register one repository-bound Engineer. Through the real UI, create a bug-fix Ticket with no
  Master Plan, classify its Profile"); DG-03 (C-P2.1, ownership), DG-05 (C-P2.3 profiles, clarification 1:
  evidence producible only during execution must not block scheduling), C-P2.5 (`createWorkOrder`,
  `admitWorkUnit`), C-P3.5 (projects, J5: only the projects folder is writable by the service), C-P3.6
  (tasks), C-P3.7 (checks; L2 `checksLost`), C-P1.5 (idempotency keys).
- Writer: the single writing agent (Implementer, manual).
- Scope: allowing Lockstep to work in a project, and handing it one ready task as a bug. **Nothing
  runs**: no process, no Git command that writes, no scheduler step, executor, reconciler or Work Unit
  admission is called by any P4.1 code path. Running work is P4.2 onward (blocked on DG-17).
- Open-gate check: P4.1 depends on no `OPEN` design gate (handoff §4, Plan v0.3 §5). It does not
  decide DG-06, DG-07 or DG-17. The Bug Profile content is recorded for the owner as O-1 in
  `docs/gates/C-EXEC/design-gates-decision-request.md`.

## 1. What P4.1 delivers

1. **Organized is not executable.** A project with a folder is still not one Lockstep may work in.
   A person must allow it, once, on the project's page. Until then, handing a task to Lockstep is
   refused.
2. **Only where Lockstep may write.** Allowing it needs a connected project whose folder is directly
   inside Lockstep's projects folder (the only folder the service may write, C-P3.5 J5) and whose
   repository is still the one registered, owned by the project's own Engineer, exclusively.
3. **The Bug Profile.** A built-in set of checks, `lockstep-bug-fix` version 1, made only of checks for
   engineering work classed `bug` (Bible §31.1). Allowing Lockstep to work in a project makes these
   checks apply to its bug work: when the project's current checks already contain them unchanged,
   they stay; when switching to `lockstep-bug-fix` loses no check (nothing chosen, or the always-on
   rules only), the project switches, with C-P2.3 decision rows; otherwise it is refused and nothing
   changes. Lockstep never removes a check a person chose.
4. **A bug handed to Lockstep.** On a ready task of an allowed project, a person can hand it to
   Lockstep as a bug. This creates exactly one C-P2.5 Work Order of kind `engineering`, class `bug`,
   for the project's Engineer and repository, at the task's priority, whose effective Profile contains
   every Bug Profile check. No Master Plan, plan reference or PhaseId exists or is needed: the Work
   Unit a Supervisor later admits for it has no plan reference.
5. **Honest pages.** The project and task pages say what is allowed and what is in line, in plain
   words, and that nothing runs yet.

## 2. Decisions

| # | Decision |
|---|---|
| X1 | **The Bug Profile** (`Lockstep.Kernel.Execution`, pure): `bugFixRaw` is the C-P2.3 document `lockstep-bug-fix` version 1, no `allows_non_behavioural` (inherited), no invariant exceptions, no specializations, five gates, each with `stage before-acceptance`, `kinds [engineering]`, `classes [bug]`, approval `supervisor`: `bug-reproduction` (artifacts `reproduction`; verifier `deterministic-command`; **exception path true**, the only one: a human exception for justified non-reproducibility, Bible §31.1), `bug-requirements` (`impact-assessment`, `requirements-basis`; `digest-check`), `bug-regression-test` (`frozen-tests`; `deterministic-command`, `digest-check`), `bug-verification` (`regression-evidence`, `verification-record`; `deterministic-command`), `bug-review` (`review-record`; `independent-review`). All before acceptance, never before execution (DG-05 clarification 1: they are produced during the work). `bugFixDefinition` is its validated definition; the stored document (`Lockstep.Application.Execution.bugFixDocument`) decodes to exactly it. |
| X2 | **Bug checks in force** (pure): `missingBugChecks gates` lists, sorted, the ids of the X1 gates not present **unchanged** (equal as C-P2.3 gates) among `gates`. The Application resolves the gates exactly as C-P2.5 `createWorkOrder` would for kind `engineering`, classes `[bug]`, no path classes, behaviour-changing, and keeps those that apply (`gateApplies`). A stricter variant of a bug check counts as missing (conservative, as C-P3.7 L2). |
| X3 | **Where Lockstep may write** (pure): `insideProjectsFolder root path` holds exactly when `path` is `root` followed by `/` and one non-empty segment without `/` (`.` and `..` are not segments). The projects folder is the one the service is given now (`LOCKSTEP_PROJECT_FOLDERS`, C-P3.5); an added folder is never inside it. |
| X4 | **Allowing Lockstep to work in a project** (`enableExecution runtime folders key project expected`), one transaction under the C-P2.3 profile lock, in this order: unknown project `unknown-project`; not connected `project-has-no-folder`; its folder not inside the projects folder `folder-read-only`; the key already used: for this project with the same request → that enablement (a replay); else `key-conflict`; already allowed (another key) `already-enabled`; ownership (X5) `ownership-invalid` or `repository-changed`; the current checks (the repository default's id, or none) differ from `expected` `checks-changed`; register `lockstep-bug-fix` version 1 (a `profile-add` decision row, accepted) when no profile `lockstep-bug-fix` exists; then X2 over the current checks: none missing → keep them; else, if `checksLost current (latest lockstep-bug-fix)` is empty and none is missing under it → set the repository default to `lockstep-bug-fix` with a `repository-set-profile` decision row (accepted); else `bug-checks-missing`. Then one enablement row: key, request digest, project, repository, Engineer name, folder, the checks in force (id, version, digest), actor `application-session`, time. A refusal writes nothing, except the `profile-add` row when the registration happened before a later refusal in the same transaction rolls back with it (the transaction commits only on success). |
| X5 | **Ownership, valid and exclusive** (`Application.Repositories.ownershipHolds`): the project's Engineer owns exactly one active repository (DG-03 D-3.5a), it is the repository the project was connected to, and the physical identity of `<folder>/.git` read now equals the registered one. Not owned, or owned by another Engineer, `ownership-invalid`; a missing or different `.git` `repository-changed`. Read-only; it changes nothing. |
| X6 | **Handing a task to Lockstep as a bug** (`admitBug runtime folders key task expected`): `expected` outside 0–2147483647 `revision-out-of-range` before anything is read; then one transaction under the task lock, then the profile lock, in this order: the key already used: same request → that admission (a replay); else `key-conflict`; unknown task `unknown-task`; the project not allowed (X4) `execution-not-enabled`; the task already handed over `already-admitted`; the task's Ticket revision differs from `expected` `stale-revision`; the task's readiness (C-P3.6 K4) is not *Ready to work on*: not yet ready / being worked on `task-not-ready`, waiting `task-waiting`, blocked `task-blocked`, a needed task canceled `task-cannot-start`, finished or canceled `task-closed`; its folder not inside the projects folder `folder-read-only`; ownership (X5); X2 over the current checks finds any missing `bug-checks-missing`; then the C-P2.5 Work Order is created **in the same transaction** (`createWorkOrderIn`): ticket = the task, Engineer = the project's, kind `engineering`, classes `[bug]`, path classes none, priority = the task's, no dependencies (the task's readiness already requires them finished), behaviour-changing. A C-P2.5 refusal maps to `task-not-ready` (`ticket-not-ready`), `bug-checks-missing` (`repository-default-profile-unset`) or `admission-refused` (any other code). Then one admission row: key, request digest, task, project, Work Order, its effective digest, actor `application-session`, time. The Ticket's state is unchanged (still ready). |
| X7 | **Request digests** (pure): `enablementRequestText project expected` = `lockstep-execution-enable-v1`, `project <uuid>`, `expected <id or none>` (one per line); `admissionRequestText task expected` = `lockstep-bug-admission-v1`, `task <uuid>`, `expected <n>`. The digest is SHA-256 of the text, as 64 lowercase hex. |
| X8 | **Reading** (`executionStatus runtime folders project`): `Nothing` for an unknown project; else `NeedsFolder` (not connected), `FolderReadOnly`, `NotEnabled (Maybe checks id)` or `Enabled enablement`. `findAdmission runtime task`: the task's admission, if any. |
| X9 | **Migration 18**: `lockstep_execution_enablements` (`id`; `idempotency_key` unique, the C-P1.5 rule; `payload_digest` 64 hex; `project_id` unique → projects; `repository_id` → repositories; `engineer_name`; `folder`; `profile_id`; `profile_version` ≥ 1; `profile_digest` 64 hex; `actor`; `enabled_at`) and `lockstep_bug_admissions` (`id`; `idempotency_key` unique; `payload_digest`; `task_id` unique → project tasks; `project_id` → projects; `work_order_id` unique → work orders; `effective_digest` 64 hex; `actor`; `admitted_at`). UPDATE, DELETE and TRUNCATE refused by trigger on both. No column names a plan or phase. |
| X10 | **Words** (`executionRefusalWords`, pure) for every code: `unknown-project`, `unknown-task`, `project-has-no-folder`, `folder-read-only`, `ownership-invalid`, `repository-changed`, `checks-changed`, `bug-checks-missing`, `already-enabled`, `execution-not-enabled`, `already-admitted`, `stale-revision`, `task-not-ready`, `task-waiting`, `task-blocked`, `task-cannot-start`, `task-closed`, `key-conflict`, `revision-out-of-range`, `admission-refused`. None contains *profile*, *gate*, *invariant*, *work order*, *ticket*, *engineer*, *scheduler*, *digest*, *supervisor*, *repositor*, *Git*, *phase*, *work unit* or *contract*. |
| X11 | **Pages.** The project page gains **Fixing bugs** (`#execution`), after How work is checked: no folder → connect one first; folder outside the projects folder → why Lockstep only reads it; not allowed → what allowing means (reproduce first, tests agreed and frozen before any change, automatic checks, independent review, the person decides when it is finished) and the form `#enable-form` (hidden `key`, `expected`, `expected_set` as C-C.R1 R10) with button `#enable-execution` "Let Lockstep fix bugs here", posting to `/app/api/projects/<id>/execution`; allowed → "Lockstep may work on bugs in this project." and "Nothing has run yet". The task page of a task in an allowed project gains **Fixing it**: when *Ready to work on* and not handed over, the form `#admit-form` (hidden `key`, `ticket_revision`) with `#admit-bug` "Ask Lockstep to fix this bug", posting to `/app/api/tasks/<id>/bug`; when handed over, "Lockstep has this bug in line to fix." and its standing from the C-P3.7 queue preview. Both answer `200` with the page (`X-Lockstep-Path`) and the outcome or the refusal in words; session header, Origin and 16 KiB as C-P3.6. The existing "Nothing runs it yet" and "cannot change it or run anything in it yet" sentences stay true and stay. Exact ids, codes and digests only under *Technical details*. |
| X12 | **No execution.** No P4.1 path calls `scheduleOnce`, the executor, the reconciler, `admitWorkUnit`, a provider, or a Git command that writes. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/ExecutionTest.hs` | unit | X1 definition (id, version, five gates, stages, scopes, verifiers, approvals, the one exception path, valid C-P2.3); the stored document decodes to it with the same digest; X2 (no gates: all five; the Bug Profile: none; a stricter variant: that one; extra gates: none); X3 (direct child, nested, the root itself, `.`/`..`, trailing slash, other root, prefix trick `root-x/a`); X7 texts and digests stable and every field changing them; X10 words for every code, non-empty, no internal word |
| `test/integration/Lockstep/ExecutionTest.hs` | integration: real PostgreSQL, real Git, in-process | no folder; folder outside the projects folder; not allowed → admission refused, nothing created; allow: registers `lockstep-bug-fix` and sets it (decision rows), enablement row; replay and `key-conflict`; `already-enabled`; from the always-on rules (switch) and from a set containing the bug checks (kept); a set without them (`bug-checks-missing`, nothing changed); stale `checks-changed`; `.git` replaced (`repository-changed`); admission: not ready, waiting, blocked, stale revision refused; ready → one Work Order (kind, class `bug`, Engineer, repository, priority, effective Profile with all five bug checks, Ticket still ready); replay, `key-conflict`, `already-admitted`; checks switched back with confirmation → `bug-checks-missing` for the next task; **nothing runs** (no schedule decision, claim, intent, job or Work Unit); the no-plan chain: the existing scheduler step claims it and `admitWorkUnit … Nothing` admits a Work Unit with no plan reference, and no table column names a plan or phase; records immutable |
| `test/integration/Lockstep/ExecutionPageTest.hs` | integration: real service | the project page's section in each state and its form's fields; the task page's section (absent when not allowed or not ready, the form when ready, "in line" after); session and Origin required; allowing and handing over answer with the page and its address; a stale or repeated form explained in words; escaping; no internal word outside *Technical details*; 404s and the 16 KiB limit |
| `test/integration/Lockstep/ExecutionBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen), real service | sign in → a project in a new folder → Let Lockstep fix bugs here (keyboard) → a task → Mark as ready → Ask Lockstep to fix this bug (keyboard) → in line → reload: still in line; afterwards one enablement, one admission, one Work Order, no schedule decision |

## 3a. Verification record (after implementation)

*(empty until implemented)*

## 4. Freeze record

Frozen 2026-10-27 by the writing agent (manual), before the operations and pages were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/ExecutionTest.hs` | `e26d8b72a53d4d61adad438b531b50aa788eb7bf3aa10396ab1ad1e4062b23f0` |
| `test/integration/Lockstep/ExecutionTest.hs` | `42ee5471d0d5dfcbd239d66e8bc67df2ffe9ed4714ad1c737f42efbd1c988c17` |
| `test/integration/Lockstep/ExecutionPageTest.hs` | `9914da5baeb60b9b91e84c70d1232165ab05e5803e970b21e33f356b80f26902` |
| `test/integration/Lockstep/ExecutionBrowserTest.hs` | `2888149bc7d1b1204955e778ed385b477b36263665a4ee0536fa73aafaf1b4cb` |
| `test/unit/Main.hs` (runner, additive) | `a427f2c04fc1f5fff7e6a1ce19a10625d35ece4e68953d6c825b93e62d4461cf` |
| `test/integration/Main.hs` (runner, additive) | `ec71f5c26274c614c73546e6a834f3ab7167177bc9f4059e3046f5556f084d84` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- The pure rules (`Lockstep.Kernel.Execution`), the stored Bug Profile document, migration 18 and
  `Lockstep.Persistence.Execution` were written before the freeze (the P3.6–P3.8 reason: a failing unit
  step hides the integration baseline). The unit group passed 8 of 8 at its first run.
- `scripts/check --integration` against stubbed `executionStatus`/`enableExecution`/`admitBug`/`findAdmission`
  and unchanged pages (`prefreeze-integration-baseline.log`, tree `6d3089a` plus the uncommitted P4.1
  files): format, lint, build (Kernel boundary and purity scan clean), unit 808 of 808 and the guard pass;
  **24 of 446** integration cases fail, exactly the 24 new ones, and all 422 earlier cases pass. Each new
  failure was read for its reason: the stub (`Nothing`, `not-implemented`), no Fixing bugs section, no form,
  no route (the 404 assertions of the last page case pass and it fails at the first 413), and the browser
  never finds "Let Lockstep fix bugs here" (its waits run out at the driver's 300 s). The fixtures ran:
  migrated databases, real Git (a folder added from elsewhere, a replaced `.git`), connected projects with
  their Engineer, ready tasks, the real service and sign-in.
- Found and fixed before the freeze: two expected orderings in the unit test (C-P2.3 keeps artifacts and
  verifiers sorted by name); a test helper shadowing another; 5 hlint hints; `ProfileFailure` has no `Show`.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Execution.hs`, `src/Lockstep/Application/Execution.hs`,
`src/Lockstep/Persistence/Execution.hs`, `src/Lockstep/Web/ExecutionPages.hs`, the four test files of §3.
Changed: `src/Lockstep/Application/Ledger.hs` (`createWorkOrderIn`, the body of `createWorkOrder` inside
the caller's transaction; `createWorkOrder` unchanged in behaviour), `src/Lockstep/Application/Repositories.hs`
(`ownershipHolds`, read-only), `src/Lockstep/Persistence/Migrations.hs` (append 18),
`src/Lockstep/Web/App.hs` and `src/Lockstep/Web/TaskPages.hs` (the sections and two routes),
`static/lockstep.css` if needed, `static/app.js` (its form-action allowlist gains the two new
addresses; added during implementation, see §3a), `src/Lockstep/Application/Tasks.hs` (`findTaskIn`, the
task view inside the caller's transaction; added during implementation), `lockstep.cabal` (generated), the two runners (additive),
`docs/gates/P4.1/**`, `docs/gates/C-EXEC/phase-report.md`, `docs/OPERATOR_GUIDE.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-03,
DG-05, C-P3.5–C-P3.7 or a source document, or any need to change a frozen test. Rollback: revert the
P4.1 commits; migration 18 only adds tables (restore the pre-migration backup, ADR-0002).
