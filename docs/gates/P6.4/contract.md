# Contract — P6.4 PRD → Master Plan, typed DAG and freeze

- Contract ID: `C-P6.4@v1`
- Status: **FROZEN** (§5)
- Authority: `.local/plans/phase-06.md` §9 (P6.4); owner decision DG-08 = Option 2
  (`docs/gates/DG-08/decision.md`, from `.local/plans/phase-06_update1.md` §3); amendment A-P6.4-1 (`amendments.md`).
- Basis: `phase-6` after `fd35945` (A-P6.3-1 applied).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

A project has one repository folder and one Engineer. Tasks (Ticket + task row) carry untyped dependencies; P6.1 makes
imported items canonical tasks. Nothing yet represents a **Master Plan**: a versioned, owner-approved, digest-bound
graph of Work Units with typed edges, citations and an authority envelope. P6.4 adds it, so that the scheduler
(P6.5) has one durable, approved specification to follow. No new scheduler, queue or execution path is introduced:
an approved plan's units **are canonical tasks**.

| # | Decision |
|---|---|
| M1 | **The plan document** `lockstep-plan` version 1 (Fleece; unknown keys refused): `title`; `mode` (`greenfield` / `brownfield`); `sources` — each `{name, sha256}` (the PRD, the architecture, …); `envelope` — `{external_effects: false, max_units, token_budget?}`; `units` — each `{key, title, phase, subphase, work_kind, profile, priority (high/normal/low), effect (local-only/external), risk (low/normal/high), provisional (bool), outputs[], acceptance[{text, cites[]}], negative[], checks[], prerequisites[], resources[]}`; `edges` — each `{dependent, prerequisite, kind (technical/human-acceptance/external)}`; `uncertainties` — each `{text, cites[]}` (questions and contradictions the owner must see). |
| M2 | **Validation** (pure, `Lockstep.Kernel.Plan.validatePlan`) refuses, listing **every** problem with a code: `empty-plan`, `duplicate-unit`, `invalid-unit-key`, `unknown-unit` (an edge names a unit that is not in the plan), `self-edge`, `duplicate-edge`, `cycle` (with the **exact edges** of one cycle, in order), `no-acceptance`, `unknown-citation` (a citation names no source), `no-sources`, `invalid-source-digest`, `duplicate-source`, `external-effect-not-authorized` (a unit is `external` or the envelope allows external effects: Phase 6 authorizes none), `too-many-units` (more than the envelope's `max_units`), `invalid-envelope`, `unknown-work-kind`, `unknown-profile` (not in the catalog), `incompatible-mode` (a `greenfield` plan with a `bug-fix` unit, or a `brownfield` plan with a `greenfield` unit). Uncertainties never refuse: they stay visible (M8). |
| M3 | **Digest.** A revision's digest is the SHA-256 of the canonical rendering of its validated document (units sorted by key, edges sorted, lists in a fixed order). The same plan always has the same digest; any change to a frozen field (DG-08 §1.1) changes it. A **unit digest** covers the unit's own fields, its incoming edges (prerequisite and kind) and the digests of the sources it cites. |
| M4 | **Revisions are immutable.** A plan belongs to one project (one plan per project in Phase 6). A proposal stores revision `n+1` with its digest, its document, who proposed it (`Human` with the session, or `Planner` with the draft that produced it) and an idempotency key (same key + same digest replays; same key + other content is `key-conflict`; the same digest proposed again is `already-proposed`, returning that revision). Stored revisions, decisions, units, edges and reconciliations refuse UPDATE/DELETE/TRUNCATE in the database. |
| M5 | **Approval is the owner's, bound to the digest.** Only an authenticated person (an operator session, through the web form) approves or rejects a **proposed** revision, naming its number and digest: a wrong digest is `stale-digest`; a decided revision is `already-decided`; a revision older than the effective one is `superseded`; no session is `forbidden`. A proposal — by a person or the Planner — is not authority (§9: "a plan proposal is not sufficient authority to execute"). The **effective revision** is the highest-numbered approved revision; there is at most one. |
| M6 | **Approval materializes canonical tasks**, in the approval's transaction: each unit of the revision is one task of the project (title, acceptance text, priority), created as a Ticket and accepted to `ready` **by the person's approval** (principal Human, signoff naming the revision and digest); a unit keeps its task across revisions (by unit key). Every edge becomes a task dependency (so readiness and hand-over follow the graph, P6.5–P6.7 type them). The approval records each unit (revision, key, task, unit digest) and edge (with kind). A Ticket-derived task and a plan-derived task are the **same kind of object** and go through the same hand-over and engine. |
| M7 | **Reconciliation** (pure `reconcilePlan`, recorded at approval): against the previous effective revision each unit is `added`, `kept` (same unit digest), `changed`, or `withdrawn`; and every unit that transitively depends over **technical** edges on a changed unit is `invalidated` (its earlier evidence no longer counts, P6.7). A withdrawn unit's task is not deleted; it is no longer part of the effective plan. A changed source digest changes every unit that cites it (M3), so a new PRD revision reconciles exactly the affected units. |
| M8 | **Visible uncertainty.** The plan page shows every revision with its state, digest, who proposed it, its problems (for a refused draft) and its uncertainties; the approval form repeats how many uncertainties the revision carries. Approving does not hide them. |
| M9 | **Bounded just-in-time elaboration** (pure `validateElaboration`): a unit's detailed Contract cites the effective revision's digest and the unit; it may add acceptance criteria, negative cases and checks, never remove or reword an approved one; it may not change the unit's edges, effect, work kind, profile or repository. Violations are listed with codes (`wrong-revision`, `unknown-unit`, `weakened-acceptance`, `removed-negative`, `removed-check`, `changed-edges`, `changed-effect`, `changed-work-kind`, `changed-profile`). It never edits the plan. |
| M10 | **The Planner drafts from a PRD.** A person requests a draft (CLI `lockstep plan draft --project ID --prd FILE [--architecture FILE]`, or the plan page): the PRD and architecture text are stored with their SHA-256. The engine worker runs one read-only Planner invocation per draft (as C-P6.3 I4: empty workspace, bounded, unique per draft, a restart finishes an unfinished draft `uncertain` without rerunning it) with answer kind `plan` (`{"kind":"plan","plan":{…lockstep-plan…}}`). The Supervisor decodes and validates it and checks that its `sources` are exactly the supplied documents with their real digests (else `source-digest-mismatch`); a valid draft becomes a proposed revision by `Planner`; an invalid one is recorded `refused` with its problems, and nothing is proposed. |
| M11 | **Durable.** Everything above is PostgreSQL state (migration 24); browser, service and helper restarts change nothing; a restart never makes a proposal effective. |
| M12 | **Standalone bugs still need no plan** (A-P6.4-1): no row a bug writes references a plan; the bug path is unchanged. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Plan` — `PlanDocument`, `PlanUnit`, `PlanEdge`, `EdgeKind`, `WorkKind`, `PlanMode`,
  `PlanProblem` (+ `planProblemCode`), `validatePlan`, `canonicalPlanText`, `unitDigestText`, `reconcilePlan`,
  `UnitReconciliation`, `validateElaboration`, `Elaboration`, `ElaborationProblem`; `findCycle`.
- Kernel: `Lockstep.Kernel.Roles` gains `AnswerPlan` (the plan document's JSON text, checked as text by the rule).
- Effects: `decodeAnswer` gains kind `plan`; the Planner's instructions gain the plan branch.
- Persistence: migration 24 — `lockstep_plans`, `lockstep_plan_revisions`, `lockstep_plan_decisions`,
  `lockstep_plan_units`, `lockstep_plan_edges`, `lockstep_plan_reconciliations`, `lockstep_plan_drafts`;
  `Lockstep.Persistence.Plans`.
- Application: `Lockstep.Application.PlanDocument` (Fleece), `Lockstep.Application.Plans` (`proposePlan`,
  `proposePlanFile`, `decidePlan`, `planView`, `requestDraft`, `draftPlans`, `effectiveUnits`), the worker phase.
- Web: the plan page `/app/projects/<id>/plan` (+ fragment), decision route
  `POST /app/api/projects/<id>/plan/decisions`, link from the project page (`project-plan`). CLI `plan propose`,
  `plan draft`.

## 3. Mandatory tests (handoff §9) → cases

| Handoff test | Where |
|---|---|
| Realistic PRD produces a coherent multi-unit DAG | integration: a scripted Planner answers a realistic PRD (the Caesura-shaped fixture) with a 5-unit plan; it is proposed, its graph and citations stored |
| Cycles are rejected with exact diagnostic edges | unit (`validatePlan`, `findCycle`); integration (proposal refused, nothing stored) |
| Missing dependencies are refused | unit (`unknown-unit`); integration |
| Contradictory source requirements remain visible | integration: uncertainties stored and shown on the page and in the approval form, after approval too |
| Unapproved plan cannot dispatch | integration: a proposed revision creates no task and no hand-over is possible; P6.5 re-tests through the scheduler |
| Approved revision and digest remain stable | unit (digest determinism, order independence); integration (rows immutable; restart; replayed approval) |
| Unauthorized edits create no effective plan | integration: no session / wrong digest / decided / superseded / Planner-proposed-only → no effective revision; direct SQL update refused |
| Bounded just-in-time elaboration preserves frozen invariants | unit (`validateElaboration`) |
| Changed source revision requires appropriate reconciliation | unit (`reconcilePlan`); integration (second revision with a new PRD digest: changed + invalidated descendants recorded, unrelated kept) |
| Ticket-derived and PRD-derived units retain canonical parity | integration: a plan unit's task is a task like any other (same view, readiness, `admitBug` hands it over) |

## 4. Verification files (to be frozen)

| File | Kind |
|---|---|
| `test/unit/Lockstep/Kernel/PlanTest.hs` | unit |
| `test/unit/Lockstep/Application/PlanDocumentTest.hs` | unit |
| `test/integration/Lockstep/PlanTest.hs` | integration (PostgreSQL, Git, scripted Planner) |
| `test/integration/Lockstep/PlanPageTest.hs` | integration (real service over HTTP) |

## 5. Freeze record

- Frozen 2026-11-14 by the single writing agent, on `phase-6` after `fd35945`, with migration 24, its persistence
  module, the routes, the plan page, the CLI and the worker phase real, and stubs for `Lockstep.Kernel.Plan`'s rules,
  `Lockstep.Application.PlanDocument` and `Lockstep.Application.Plans`. The Planner's `plan` answer kind (Kernel rule,
  decoder, instructions) is real.
- Frozen files (`scripts/format`, lint: no hints, `shasum -a 256`):

  | File | sha256 |
  |---|---|
  | `test/unit/Lockstep/Kernel/PlanTest.hs` | `29bbe2e0f580f35f955e307f6a05ce1addc4c20afec905c30680d708e3cdffd2` |
  | `test/unit/Lockstep/Application/PlanDocumentTest.hs` | `e473a3c537e32e0b0895828553cad20494cfc2fe4c5b91f407c678a3dbc49180` |
  | `test/integration/Lockstep/PlanTest.hs` | `ba6239f10e5ffadf6b6a6dc42348342da72e7a0cd80718548b597784d5e1a09d` |
  | `test/integration/Lockstep/PlanPageTest.hs` | `01efd671a3ab25ff7a2f34490206ff12a0cf6613b3c43ad337f9c94c6bd24d3f` |
  | `test/unit/Main.hs` (shared; supersedes earlier digests, additive) | `e553384b5b232a61f56122c8bfe1dd259db0f678f151386e4c9bbceea5df19e4` |
  | `test/integration/Main.hs` (shared; supersedes earlier digests, additive) | `122ce795d486b503e3b631db0d641c33bde1ee4f7e6e75877a796e63260da7ea` |
  | `test/integration/Lockstep/ExecutionTest.hs` (A-P6.4-1, `amendments.md`) | `532fb5cd515fbb34c127e853329396bb657b3139eb4452c7524042ae88d462e8` |

- Baseline: unit **32 of 35 fail** (the 3 that pass: a valid plan comes back unchanged — the stub returns its input;
  the outcome codes — real constants; an elaboration with no problem — the stub returns none); integration **12 of 12
  fail**, each at the stubbed proposal, draft or decision. The amended C-P4.1 case passes with migration 24 applied.
  Logs `.local/evals/phase-06/p64-baseline-{unit,integration}.log`, `a641-execution.log`.
- Clarifications fixed at freeze (no test change): the envelope's `max_units` is 1–200 (outside: `invalid-envelope`);
  the same plan proposed again under another key is refused `already-proposed` (no new revision); the plan's
  `profile` may name Lockstep's built-in Profiles (`lockstep-bug-fix`, `lockstep-basic`) or any in the catalog;
  there are no plan fixture files (the tests build their documents).

## 6. Allowed paths

New: the files in §2/§4, `docs/gates/P6.4/**`, `docs/gates/DG-08/decision.md`. Changed: `Kernel/Roles.hs`,
`Effects/Roles.hs`, `Effects/Provider/Claude.hs`, `Persistence/Migrations.hs` (append 24), `Application/EngineWorker.hs`,
`Web/App.hs`, `Web/Routes/App.hs`, `Web/Routes/Params.hs`, `Web/TaskPages.hs` (project link), `static/app.js`,
`app/lockstep/Main.hs`, `package.yaml`, the test runners, `docs/OPERATOR_GUIDE.md`, the DG-08 register row,
`test/integration/Lockstep/ExecutionTest.hs` (A-P6.4-1 only).

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. No provider call (scripted Planner only); a live PRD draft is NOT_RUN.
Rollback: the branch; migration 24 is additive.
