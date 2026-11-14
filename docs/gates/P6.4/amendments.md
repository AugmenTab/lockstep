# C-P6.4 — frozen-test amendments and contract text corrections

## Contract text corrections (R-P6.4, no test changed)

- **M10:** a draft is requested by the CLI (`plan draft`) only; the plan page shows drafts but has no draft form in
  this subphase. **§2:** `effectiveUnits` is not part of P6.4 (P6.5 reads the effective revision itself).
- **M6:** the Ticket accept is the plain C-P2.2 accept by principal Human (a Ticket accept carries no signoff); the
  approval's provenance is the decision row (revision, digest, actor — `application` from the web, as the other
  C-P3/C-P4 decisions record, or `command-line`) and `lockstep_plan_units`. **M4:** "Human with the session" reads
  "Human, with the channel (`owner-session`/`application`/`command-line`)".
- **M4:** `already-proposed` holds only while a revision with the same digest waits for a decision or is in effect
  (R-P6.4-4, migration 25); it is a refusal, it returns no revision.
- **M7:** a later approval writes a task only where its unit's text changed, refuses `locally-edited` over a
  person's edits, keeps a person's dependencies outside the plan, blocks a withdrawn unit's task and unblocks it when
  the unit returns (R-P6.4-1, -2).
- **M2:** adds `invalid-acceptance` and `uncited-criterion` (R-P6.4-5, -9).
- **M9:** "or repository" is struck: a project has one repository in Phase 6, so an elaboration cannot change it.

## A-P6.4-1 — the C-P4.1 blanket ban on `plan`/`phase` column names (AUTHORIZED, APPLIED)

- **Authority:** the owner, 2026-11-14, `.local/plans/phase-06_update1.md` §4 ("Recommended narrow amendment
  authority"), on the question in `docs/gates/DG-08/decision-packet.md` §4 (choice A). The update's words are
  "authorize preparation of the exact frozen-test amendment … Only remove the obsolete blanket schema-naming
  restriction"; the Implementer reads this, with §7 ("implement P6.4"), as authority to apply it. If the owner meant
  preparation only, revert this one commit's change to `ExecutionTest.hs`; P6.4's tables would then need renaming.
- **File:** `test/integration/Lockstep/ExecutionTest.hs`, case "no plan is needed: …" (C-P4.1).
- **Invariant kept:** a standalone bug needs no Master Plan. Unchanged assertions in the case: the existing
  scheduler step claims the bug's Work Order; its Work Unit is admitted with `plan_ref IS NULL`; the Work Unit row names
  the bug's Work Order and Ticket.
- **Removed** (lines 437–438 as frozen): "no column of any `lockstep%` table contains `phase`" and "no column of any
  `lockstep%` table contains `plan`, except `lockstep_work_units.plan_ref`".
- **Added in their place** (the same guarantee, stated about the rows a bug actually writes — `bugTables`: tickets,
  project tasks, subjects, Work Orders, bug admissions, Work Units, schedule decisions, transactions, enablements):
  1. none of those tables has a **NOT NULL** column whose name contains `plan` or `phase`;
  2. none of those tables has a **NOT NULL** column that is a foreign key to a table whose name contains `plan`.
  Plan tables may now exist beside them (P6.4). The case title says "none of its rows requires a plan or phase"
  instead of "no column names a phase". The only other change to the file is the new top-level helper `bugTables`
  (the list of those tables) next to `countsAre`. *(Corrected per R-P6.4-10; the first record said "no other line".)*
- **Limitation (R-P6.4-10):** the new checks reach NOT NULL columns and NOT NULL foreign keys of the nine named
  tables only; a trigger requiring a plan, or a plan requirement on another table the bug path writes (such as
  `lockstep_task_dependencies`), would not be caught by this case. The bug-path tests of C-P4.x would.
- **Digests of `test/integration/Lockstep/ExecutionTest.hs`:** before
  `42ee5471d0d5dfcbd239d66e8bc67df2ffe9ed4714ad1c737f42efbd1c988c17`, after
  `532fb5cd515fbb34c127e853329396bb657b3139eb4452c7524042ae88d462e8`.
- **Coverage of standalone tickets after the amendment:** this case (claim with no plan, `plan_ref IS NULL`, the two
  NOT NULL checks), and every C-P4.x/C-P6.x engine test, which admits bugs with no plan at all.
