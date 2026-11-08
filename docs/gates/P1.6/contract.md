# P1.6 Contract — Small truthful command center and evidence UI

- Contract ID: `C-P1.6@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `fd518ba`. P1.3–P1.5 `VERIFIED — awaiting human acceptance`.
- Authority: `.local/plans/phase-01.md` §P1.6 and operating rule 4; the owner's instruction of
  2026-10-18 ("Continue into P1.6 and P1.7 if all required checks pass"). Governing design
  contract: `docs/VISUAL_EVIDENCE_CONTRACT.md` (ACCEPTED at Gate P0) §2–§4, §8–§10;
  `docs/TESTING_STRATEGY.md` §2.1 ("projection re-derivation"). No open decision gate applies.
- Traces: FR-APP-02/05/09 (primitive), NFR-12, NFR-14; Plan v0.2 P1.6 ("actual operation visibly
  changes UI; method, status and durable receipt visible; not-run cannot render green; no fake
  running engineer").
- Writer: the single writing agent (manual; no v2 Supervisor).

## 1. Objective

A protected operator page, `/operator/center`, rendered only from canonical PostgreSQL rows: a
status summary, recent command activity (receipts and refusals), and an evidence matrix
`criterion → method → expected → actual → disposition → evidence locator` for the background
jobs. A pure evidence model makes an unsupported `PASSED` unrepresentable, so a job that is
queued, running, failed, tampered with or missing its evidence can never render as passed.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Pure evidence model** `Lockstep.Foundation.EvidenceModel` (VISUAL_EVIDENCE_CONTRACT §10 names `Lockstep.Evidence.Model`; it lives under Foundation so the existing Henforcer layering covers it without a config change). Types: `Disposition = Passed \| Failed \| Inconclusive Text \| Blocked Text \| NotRun Text`; `EvidenceItem { locator, sha256, kind, producer }`; `TestedRevision { commit, dirty }`; `RowInput { criterionId, statement, sourceRefs, required, method, expected, actual :: Maybe Text, claimed :: Disposition, evidence :: [EvidenceItem], testedRevision :: Maybe TestedRevision }`. |
| E2 | **Rules (VISUAL_EVIDENCE_CONTRACT §4).** `effectiveDisposition :: Text (declared revision) -> (Text -> Maybe Text) (locator → current SHA-256) -> RowInput -> Disposition`: (rule 2) a claimed `Passed` without an actual observation, without evidence, without a tested revision, or with `dirty = True` → `Inconclusive "incomplete evidence"`; (rule 3) any evidence whose locator resolves to `Nothing` → `Inconclusive "evidence unavailable"`; any digest that differs → `Inconclusive "evidence changed"`; (rule 4) a `Passed` whose tested commit differs from the declared revision → `Inconclusive "stale revision"`, while a stale `Failed` stays `Failed`. Rules 3–4 apply to claimed `Passed` rows; other dispositions keep their claim. `aggregate :: [(Bool required, Disposition)] -> Disposition`: worst required by `Failed > Blocked > Inconclusive > NotRun > Passed`; no required rows → `NotRun "no required rows"`. `dispositionLabel` gives `PASSED`, `FAILED`, `INCONCLUSIVE (<why>)`, `BLOCKED (<why>)`, `NOT_RUN (<why>)`; `dispositionClass` gives `ls-passed`, `ls-failed`, `ls-inconclusive`, `ls-blocked`, `ls-not-run`. Only an effective `Passed` yields the `PASSED` label or the `ls-passed` class. |
| E3 | **Job outcome evidence.** Migration `0005` adds `lockstep_jobs.outcome_digest bytea` (NULL until terminal). When the dispatcher sets a terminal state it stores `SHA-256(canonical)` with `canonical = "lockstep-job-outcome-v1\n" <> id <> "\n" <> state <> "\n" <> steps_done <> "/" <> steps_total <> "\n" <> (last_error or "")`, in the same update. On render, the canonical text is recomputed from the current row and compared (rule 3). |
| E4 | **Job rows of the matrix.** One row per job (newest 20): criterion `AC-JOB-<id>@v1`, statement "Job <id> (receipt <r>) completes all <n> steps", source refs `C-P1.5 E4`, `receipt <r>`, required `true`, method `background dispatcher (lockstep serve)`, expected `succeeded, <n>/<n> steps`, actual `<state>, <done>/<n> steps[, error: …]`. Claimed disposition: `succeeded` → `Passed`; `failed` → `Failed`; `queued` → `NotRun "queued"`; `running` → `NotRun "in progress"`. Evidence: `db:lockstep_jobs/<id>` with the stored digest; none if the digest is NULL. Tested revision `{commit = "schema <revision>", dirty = False}` against the declared revision `schema <current revision>`. The matrix also shows the aggregate as the machine summary, labelled "not acceptance", in an element carrying `data-aggregate="<label>"`. Each matrix `<tr>` carries `data-criterion="<id>" data-disposition="<effective label>"` (in that order). |
| E5 | **Status summary (comprehension fix, handoff §P1.6).** One semantic `<table>` (`<caption>`, `<th scope="col">`, `<th scope="row">`) where every row pairs **status label + count + description** in the same row: jobs `queued`, `running`, `succeeded`, `failed`; receipts `applied`, `queued`, `refused_stale`. Counts come from `count(*)` over the canonical tables at render. No floating badges, no legend separate from its numbers. Each row's `<tr>` carries `data-status="<jobs\|receipts>:<status>" data-count="<n>"` (in that order) for machine checks. |
| E6 | **Activity.** A table of the newest 20 receipts: id (link to `/operator/receipts/<id>`), command, outcome, actor, accepted time, and job state if any. `refused_stale` receipts are listed as refusals with their current revision. |
| E7 | **Permitted actions.** The page links the existing rename form (`/operator`) and the queue form (`/operator/jobs/new`); nothing new mutates state. A **Refresh** link reloads the page; there is no polling (VISUAL_EVIDENCE_CONTRACT §8: live updates must not move focus). |
| E8 | **Styling (NFR-12).** `static/lockstep.css` gains disposition classes and table styles with tokens for light and dark themes. Status is always text; green (`--ls-passed-*`) is used only by `ls-passed`; `ls-not-run` is neutral gray with a **dashed** outline. Each disposition's foreground/background pair meets WCAG 2.2 AA (≥ 4.5:1) in both themes. Visible focus ring kept. |
| E9 | **Route.** `GET /operator/center` (protected, P1.3 guard and session; `no-store`, `no-referrer`). `/operator` links to it. Without a ready database: 200 with an "unavailable: database not ready" notice and no matrix rows (never a green summary). |
| E10 | **Rendered-UI inspection.** A headless Chromium screenshot of the page, labelled `SCREENSHOT — shows rendering, not correctness` with route, commit, data source and capture time, is recorded as evidence and inspected; it supports review and is not proof (NFR-14). |
| E11 | **Layering.** `Lockstep.Foundation.EvidenceModel` (pure); `Lockstep.Application.CommandCenter` (reads counts, receipts, jobs; computes digests); `Lockstep.Persistence.CommandCenter` (queries); `Lockstep.Web.CommandCenter` (Brigid view). No Henforcer change, no new dependency. |

## 3. Allowed paths

As C-P1.5 §3, plus `static/lockstep.css` and `docs/gates/P1.6/**`. Frozen P1.1–P1.5 tests are
not editable.

## 4. Production API the tests bind to

```haskell
-- Lockstep.Foundation.EvidenceModel
data Disposition = Passed | Failed | Inconclusive Text | Blocked Text | NotRun Text
data EvidenceItem = EvidenceItem { evidenceLocator :: Text, evidenceSha256 :: Text, evidenceKind :: Text, evidenceProducer :: Text }
data TestedRevision = TestedRevision { revisionCommit :: Text, revisionDirty :: Bool }
data RowInput = RowInput { rowCriterion :: Text, rowStatement :: Text, rowSourceRefs :: [Text], rowRequired :: Bool, rowMethod :: Text, rowExpected :: Text, rowActual :: Maybe Text, rowClaimed :: Disposition, rowEvidence :: [EvidenceItem], rowTestedRevision :: Maybe TestedRevision }
effectiveDisposition :: Text -> (Text -> Maybe Text) -> RowInput -> Disposition
aggregate :: [(Bool, Disposition)] -> Disposition
dispositionLabel :: Disposition -> Text
dispositionClass :: Disposition -> Text

-- Lockstep.Web.CommandCenter
data MatrixRow = MatrixRow { matrixInput :: RowInput, matrixEffective :: Disposition }
renderMatrix :: [MatrixRow] -> ByteString      -- the <table> fragment, for tests
```

## 5. Tests

Unit:

| Area | Cases |
|---|---|
| Rules | each clause of E2 with a concrete row; a stale `Failed` stays `Failed`; non-`Passed` claims are never upgraded |
| Exhaustive generation | every combination of claim (5) × actual present (2) × evidence (none / matching / changed / unavailable) × revision (none / clean current / clean stale / dirty current): the effective disposition is `Passed` **iff** the claim is `Passed`, actual present, evidence non-empty and all matching, revision clean and current |
| Aggregate | worst-of order; non-required rows ignored; empty → `NotRun` |
| Labels | `PASSED`/`ls-passed` only for `Passed`; other labels include the reason |
| Rendering | for generated rows, every non-`Passed` effective row renders without `ls-passed` and without the text `PASSED`; every row shows criterion, method, expected, actual (or `—` with `NOT_RUN`), label and locator; the table has `<th scope="col">` headers |
| CSS | the stylesheet defines every disposition class; `ls-not-run` has a dashed border; light and dark foreground/background tokens for each disposition reach ≥ 4.5:1; green tokens appear only in `.ls-passed` |
| App (no database) | `GET /operator/center` without a session → 401 |

Integration (real PostgreSQL and the real binary):

| Case | Asserts |
|---|---|
| Truthful projection | with jobs succeeded, failed, queued (no service run for it) and a stale rename refusal: the page's summary counts equal SQL counts; each job row shows its effective label (`PASSED`, `FAILED`, `NOT_RUN (queued)`); the refusal is listed; the aggregate is `FAILED` |
| Tampered evidence | after `UPDATE lockstep_jobs SET steps_done = 2` on a succeeded job, its row shows `INCONCLUSIVE (evidence changed)` and no `PASSED` |
| Missing evidence | after `outcome_digest = NULL` on a succeeded job: `INCONCLUSIVE (incomplete evidence)` |
| Visible change | queueing a job through the operator action makes it appear in activity and the `queued` count rises by one |
| Database not ready after sign-in / no session | 401 without a session; after a forged future ledger row makes readiness fail (the session still validates), the page renders the "unavailable" notice, no matrix row and no `PASSED` |
| Backup gate | revision 4 → `db migrate` without a flag → exit 75; `--no-backup` applies `0005` |

## 6–7. Verification, budget, stop, rollback

As C-P1.5 §6–§7, plus the screenshot of E10 inspected and recorded. **Pre-freeze rule (lesson of
P1.5): the candidate integration suite is run against the current binary before the freeze, and
every failure must be the expected missing feature.**

## 8. Freeze record

Frozen 2026-10-18 by the writing agent (manual; no v2 Supervisor). Frozen test files never
change in P1.6.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/EvidenceModelTest.hs` | `6aceb81ad96dd5f5691903d290e4f43b893e07a6a40d3b8556fc58ccf4b25944` |
| `test/unit/Lockstep/Web/CommandCenterViewTest.hs` | `62b43828d34ed76a12279ca5a623edbf0ffdf729e9c80fea5b353670cc90a5bb` |
| `test/integration/Lockstep/CommandCenterTest.hs` | `d022a64a846f42d807758044925bdec3d53715fc70d7c46b27a85623fa74e327` |
| `test/unit/Main.hs` (runner, additive) | `badcd878407bdb331d605b7036241db8f86d188dd855140b24aaa209ab856b6b` |
| `test/integration/Main.hs` (runner, additive) | `66c38afd3497b06a281342f6c2f42f3c21fa855ece671e22173069b6a1c7b04d` |

Runner changes (additive only): `test/unit/Main.hs` gains `EvidenceModelTest`,
`CommandCenterViewTest` (4 lines); `test/integration/Main.hs` gains `CommandCenterTest` (2 lines).
The integration test uses the frozen `Support/Process.withService` (whose `waitReady` handles a
starting server) and polls with one query per iteration (C-P1.5 §9.2 known issue).

Pre-freeze verification (now including a **run**, per the P1.5 lesson):
- With type-only stubs (scratch, not committed: `Lockstep.Foundation.EvidenceModel`,
  `Lockstep.Web.CommandCenter`): format, lint and build (`--pedantic`, unchanged Henforcer
  configs) PASSED; the unit suite ran with 24 failures, every one in the new modules' stubbed
  behaviour (`evidence/prefreeze-run-against-stubs.log`).
- The integration suite ran against the current binary with 4 failures, all the missing feature:
  `/operator/center` answers 404 (three tests, each after its setup succeeded: renames, queued
  jobs settled by the real dispatcher, sign-in) and `db migrate` finds no migration `0005`
  (`evidence/prefreeze-integration-against-current-binary.log`). All 58 earlier tests passed.
