# DG-08 — Master Plan approval, freeze and amendment semantics (decision request)

- Decision: **DG-08** (`docs/governance/DECISION_REGISTER.md`: "Plan import/creation freeze and local Phase signoff",
  OPEN). Required before P6.4 freezes its governed plan-freeze Contract (handoff `.local/plans/phase-06.md` §8; PRD
  v0.4 §7; Plan v0.4 §6).
- Prepared by: the single writing agent (Implementer), 2026-11-14, on `phase-6`. **Not a decision.** The Implementer
  records nothing as ACCEPTED; P6.4's freeze waits for the owner's answer. Independent P6 work continues meanwhile.
- Related, already approved as *directions* (Bible v2.3 §8): D6-AUTH (one approved plan/authority envelope permits
  automatic local dependency-ready progression; final Human Done separate). DG-08 fixes *what* is approved and
  frozen; D6-AUTH fixes what approval *permits*.

## 1. The question

When the owner approves a Master Plan, what exactly becomes immutable, what may the Planner still refine without a
new approval, and what happens to work already done when the plan changes?

## 2. Options

| | Option 1 — everything frozen upfront | **Option 2 — immutable outline, bounded just-in-time Contracts (recommended)** | Option 3 — Planner-editable active plan |
|---|---|---|---|
| What the owner approves | Every Work Unit's full implementation Contract, tests and file list | One plan revision: units, edges, acceptance, owners, effects, Profiles, envelope | An initial plan; later edits need no approval |
| When a unit's Contract is written | Before anything runs | Just before the unit runs, by the Planner, inside the approved boundary | Any time |
| Owner effort | Very high, and much of it before facts exist | One approval per meaningful revision | Lowest |
| Risk | Contracts written blind go stale; pressure to approve without reading | Bounded: elaboration cannot change approved fields; violations refuse | Planner can silently change scope, edges, tests or effects — contradicts B23-11, FR-PLAN-03/05 |
| Fit to governing documents | Legal but impractical; contradicts B23-02 (minimal human attention) | Matches B23-03, B23-11 ("specifies the next unit just in time inside the approved scope"), FR-PLAN-03 | **Not permitted** by FR-PLAN-05 and B23-11 ("A revised plan is versioned, not silently substituted") |

## 3. Recommended semantics (Option 2)

### 3.1 A plan revision

A Master Plan has immutable, numbered **revisions**. A revision is *proposed* (Planner or person), then *approved*
or *rejected* by the owner. At most one revision of a plan is *effective*. Approval is an authenticated Human
decision bound to the revision's digest; the deterministic Supervisor checks the digest at every dispatch.

### 3.2 Immutable in an approved revision (digest-bound)

1. Source PRD and architecture documents, by identity and SHA-256.
2. Work Units: stable identity, title, phase/subphase placement, repository owner.
3. Each unit's required outputs and objective acceptance criteria (with source citations), and required negative
   evidence.
4. Dependency edges and their kind (technical / human-acceptance / external).
5. Effect and risk class per unit (local-only vs anything external or irreversible).
6. Effective Profile per unit (identity + digest) and the technical progression policy (which edges may be
   satisfied provisionally, D6-AUTH).
7. The authority envelope: allowed operations, environment and network policy, resource and model-usage budgets,
   escalation rules.
8. Owner priorities (DG-05 ordering applies within them).

### 3.3 Refinable without a new approval (just-in-time elaboration)

The Planner may write a unit's detailed **Work Unit Contract** (implementation approach, file-level plan, the
concrete candidate tests that satisfy the approved acceptance criteria, ordering of steps inside the unit) only when:

- it cites the approved revision digest and the unit;
- it adds tests and checks but never removes or weakens an approved acceptance criterion or negative case;
- it touches only the unit's repository and the paths/effect class approved for it;
- it does not add, remove or retarget a dependency edge, and does not change any field in §3.2.

The Supervisor validates each elaborated Contract against the approved revision before freeze; a violation refuses
the Contract (the unit waits, with the reason) — it never edits the plan.

### 3.4 Amendment triggers (a new proposed revision is required)

Any change to a §3.2 field; a discovered need for a new unit or edge; a changed source PRD/architecture digest; a
budget or authority increase; a Planner finding that an approved acceptance criterion is wrong or contradictory.
The current revision stays effective for unaffected units until the owner decides (or the owner suspends it).

### 3.5 Effect of a new revision on existing work

- Old revisions and all their evidence stay immutable and visible.
- The Supervisor computes a deterministic **reconciliation**: units unchanged in identity *and* every §3.2 field keep
  their accepted evidence; changed units, and their transitive descendants over technical edges, lose eligibility
  and are marked `INVALIDATED` (by revision) until re-verified under the new revision; removed units are recorded as
  withdrawn, never deleted.
- An accepted local commit is never rewritten. Effects already applied, uncertain (`EFFECT_UNKNOWN`) or external
  are never assumed undone; they appear in the reconciliation for the owner.
- Active work on an affected unit stops at the next safe boundary (no new invocation is started under the old
  revision).

### 3.6 Recovery

Plan state (revisions, approvals, effective pointer, reconciliation) is durable in PostgreSQL and survives browser,
service and helper restarts. A restart never makes an unapproved revision effective, and never re-dispatches a unit
whose evidence settled under a revision that is still effective.

### 3.7 Local Phase signoff (the second half of DG-08's original title)

Recommend: a Phase (group of units) has no separate signoff gate in Phase 6; final Human Done stays per Ticket/unit
(B23-13) and Gate D is the owner's acceptance. A "Phase complete" view is a projection, not an authority.

## 4. A frozen-test constraint the owner should rule on

The frozen C-P4.1 integration test `test/integration/Lockstep/ExecutionTest.hs:437-438` (case "no plan is needed …")
asserts that **no column of any `lockstep%` table contains `phase`, and none contains `plan`** except
`lockstep_work_units.plan_ref`. Its purpose was to show a bug needs no plan. P6.4 needs durable plan revisions,
which naturally have columns such as `plan_id`, `plan_revision`, `phase`.

| Choice | Effect |
|---|---|
| **A (recommended).** Amend the case narrowly (A-P6.4-1): keep "a bug's Work Order, Work Unit and Ticket need no plan" (no NOT NULL plan reference on those rows; the bug still claims with `plan_ref IS NULL`), and drop the global column-name ban. | Honest schema names; the original guarantee is kept and still tested. Needs the owner's authority (frozen test). |
| B. Keep the test; name the new schema without `plan`/`phase` (e.g. `lockstep_programmes`, `stage`). | No amendment, but it satisfies the test's letter by renaming, which risks being test-shaped naming; UI and code would still say "plan". |

## 5. What the owner is asked to decide

1. DG-08 semantics: **Option 2 as in §3** (or Option 1, or amendments to §3.2–§3.5).
2. Local Phase signoff: **none in Phase 6, as in §3.7** (or a different rule).
3. The frozen-test question in §4: **A** (authorize amendment A-P6.4-1 as described) or **B**.

Until answered: P6.4's graph model, validation and Planner proposal may be designed and tested as pure code, but no
P6.4 Contract is frozen, no plan approval is implemented as an authority, and P6.5–P6.7 (which depend on it) do not
start.
