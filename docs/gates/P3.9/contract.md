# Contract — P3.9 Activity, evidence and recovery visibility

- Contract ID: `C-P3.9@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.9 ("a comprehensible Activity and Evidence interface over real
  persisted state"; "surface failures, blockers and next actions prominently"; "retain
  inspectable technical details and raw evidence"; distinguish PASSED, ATTESTED, FAILED, BLOCKED,
  UNKNOWN / RECONCILIATION_NEEDED, NOT_RUN; "do not present a human attestation as independently
  verified"; "do not turn missing telemetry into success"); PRD v0.3 FR-UX-09 ("browser
  disconnect or restart must not misstate durable state"); Plan v0.3 §4 P3.9; C-P2.8 (the
  projection and the effect status table, **unchanged**: this view adds words, never a status);
  C-P3.8 (decisions).
- Writer: the single writing agent (Implementer, manual).
- Scope: the **Activity** section, built only from the C-P2.8 projection read in one snapshot. No
  new table, no migration, no ledger or Kernel status rule.

## 1. What P3.9 delivers

1. **What needs attention first.** At the top of Activity: every step that cannot go on without
   a person or a recovery, and every piece of stopped work, each with what to do next (a link to
   its decision where one exists).
2. **Every piece of work, with every step.** Grouped by the task it came from: the work's state in
   plain words, and each step with its exact C-P2.8 status label and a sentence saying what that
   label means. Work with no recorded step says so; it is never shown as passed.
3. **Honest statuses.** The label is the C-P2.8 label, unchanged: PASSED only when the
   destination's own answer settled the step; ATTESTED says a person said so and Lockstep did not
   check it; NOT_APPLIED with no retry left is shown as **FAILED** in words (the label stays);
   UNKNOWN and RECONCILIATION_NEEDED are never success.
4. **Refusals.** Requests Lockstep refused, in plain words, with what they were about.
5. **Raw evidence.** Under *Technical details*: the canonical C-P2.8 text of the whole ledger
   (`renderProjection`), each step's observations, recoveries and resolutions, and the time the
   page was read.
6. **The same after a restart.** Everything comes from the database; the ordinary text of the page
   is byte-for-byte the same before and after the service restarts.

## 2. Decisions

| # | Decision |
|---|---|
| N1 | **Words** (pure, `Lockstep.Kernel.Activity`): `statusMeaning :: EffectStatus -> Bool -> Text` (the Bool: a retry is left), one sentence per status; `nextStep :: EffectStatus -> Bool -> Maybe Text`; `needsAttention :: EffectStatus -> Bool -> Bool` = UNKNOWN, RECONCILIATION_NEEDED, BLOCKED, or NOT_APPLIED with no retry left; `orderStateWords :: WorkOrderState -> Text` for all nine states; `refusalMeaning :: Text -> Text` for the C-P2.5 refusal codes (a general sentence for any other). The PASSED sentence is the only one that says the step took effect "confirmed by the destination"; the ATTESTED sentence says "a person said … Lockstep did not check it". No Work Order, Ticket, intent, generation, Supervisor or scheduler word. |
| N2 | **Reading** (`Lockstep.Application.Activity.readActivity`): the projection (`projectLedger`), its time, and the canonical text, from one read. Work is grouped by its Ticket's title, ordered by title then work id; steps in projection order. A projection that cannot be read is shown as such, never as an empty ledger. |
| N3 | **Retry left**: from the step's own facts (dispatches ≤ budget), exactly as C-P2.8 computes its NOT_APPLIED reason. |
| N4 | **Page** (`/app/activity`, the existing section fragment): *Needs attention* (each item: the task title, the step or "the work", the label, the meaning, the next step, and a link `/app/decisions/<id>` for an UNKNOWN step or stopped work); *All work* (per task: each work's state words, each step with `<span class="ls-effect-…">LABEL</span>`, meaning, and *Technical details* per step with its raw lines); *Refused requests*; *Technical details* with the canonical text in `<pre>` and the read time. Nothing with the PASSED class or label appears for any status but PASSED. When there is no work: "Nothing has happened yet." |
| N5 | **No action here.** Activity has no form or button; decisions happen on their own pages (C-P3.8). |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/ActivityTest.hs` | unit | a meaning for every status (with and without a retry), only PASSED claims confirmation by the destination, ATTESTED says a person said it and it was not checked, FAILED wording only for NOT_APPLIED without a retry; attention exactly for UNKNOWN, RECONCILIATION_NEEDED, BLOCKED and failed; next steps; words for every work state and refusal code; no internal words |
| `test/integration/Lockstep/ActivityPageTest.hs` | integration: real service on a `withLedger` database, steps made through the real ledger | each of PASSED, ATTESTED, UNKNOWN, NOT_RUN and failed (NOT_APPLIED, no retry left) shown with its label and meaning, attention first with decision links; a work with no steps is not shown as passed; refusals in words; the canonical text under *Technical details* equals `renderProjection`; the ordinary text is identical after a service restart; no form or button; escaping; no internal words outside *Technical details* |
| `test/integration/Lockstep/ActivityBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen) | Home → Activity → the step that needs a person → its decision page |

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the Activity page was implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/ActivityTest.hs` | `50003ffb80d584aa7ee5fdcd342118fc3ffcb1df28227c103fa6a04c67c4697f` |
| `test/integration/Lockstep/ActivityPageTest.hs` | `b2427e7cd0fb9e628fabd3deef94168b22dbcf1a4e4c1645fabe4bbcafcd3a81` |
| `test/integration/Lockstep/ActivityBrowserTest.hs` | `a83ac1450ff88cb6c26ab372f554a95256161a664f9803c54f513c15e7dabe1f` |
| `test/unit/Main.hs` (runner, additive) | `11254c03efed353d973dd0af97a6cf725efaf44150fd6bdaa31cf9771663113d` |
| `test/integration/Main.hs` (runner, additive) | `cea4e7e37a0d7d46db3166e569ff0838895f8a30b660636755e0b493267a62fe` |

Earlier frozen tests are untouched (the C-P3.8 fixtures in `Support/Decisions.hs` are reused, not
changed); the runners only gain lines.

Pre-freeze verification:

- The pure words (`Lockstep.Kernel.Activity`) and the reading (`Lockstep.Application.Activity`)
  were written before the freeze; the unit group passed 8 of 8 at its first run
  (`prefreeze-unit.log`), not against a stub first (the P3.6–P3.8 reason).
- `scripts/check --integration` with the Activity section unchanged
  (`prefreeze-integration-baseline.log`): format, lint, build, unit and guard pass; 8 of 381
  integration cases fail: the 2 known `HandoverTest.hs` cases and all 6 new ones, each on the old
  placeholder section; the fixture (stopped work, then five real steps: settled, attested, no
  answer, refused twice, never sent; a stale refusal) ran before every assertion.
- Found and fixed before the freeze: an unused fixture field (the never-sent step's id is now
  asserted in the raw evidence).
