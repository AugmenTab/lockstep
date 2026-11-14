# C-P6.4 — frozen-test amendments

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
  instead of "no column names a phase". No other line of the file changed.
- **Digests of `test/integration/Lockstep/ExecutionTest.hs`:** before
  `42ee5471d0d5dfcbd239d66e8bc67df2ffe9ed4714ad1c737f42efbd1c988c17`, after
  `532fb5cd515fbb34c127e853329396bb657b3139eb4452c7524042ae88d462e8`.
- **Coverage of standalone tickets after the amendment:** this case (claim with no plan, `plan_ref IS NULL`, the two
  NOT NULL checks), and every C-P4.x/C-P6.x engine test, which admits bugs with no plan at all.
