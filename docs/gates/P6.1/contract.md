# Contract — P6.1 Canonical backlog and source intake

- Contract ID: `C-P6.1@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-06.md` §5 (owner-authorized Phase 6 handoff; "Implement P6.1–P6.9 in dependency
  order"); PRD v0.4 FR-PLAN-01, FR-PLAN-04; Plan v0.4 §4 P6.1; Bible v2.3 B23-10; D6-SOURCE (approved direction).
- Basis: `phase-6` from `6589fe2` (stabilization-1 tip: the installed `d00e26c` plus documentation and one host check
  script; no source change since `d00e26c`).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

Work reaches the engine one way today: a **task** (a C-P2.2 Ticket plus its row, C-P3.6) that a person marks ready
is handed over (`admitBug`, C-P4.1) and becomes an Engineering Work Order, which the engine worker starts
(`Engine.startTransactionFor`). P6.1 does **not** add a second item type, queue or engine. An imported backlog
item **is a task**; what is new is where it came from.

| # | Decision |
|---|---|
| B1 | **One canonical item: the task.** An imported item is created as an ordinary task (Ticket + `lockstep_project_tasks` row + `lockstep_task_dependencies`) through the same storage functions `createTask` uses. Its provenance lives beside it in `lockstep_task_sources`. A task without a source row is an internal (local) task; nothing about it changes. |
| B2 | **Source identity.** A source is (provider, locator): provider `canonical`, `jira` or `shortcut`; locator 1–200 characters, no control character or space (e.g. `https://acme.atlassian.net/projects/CAE`). An item is identified by its source and its key (1–100 characters of `A-Z a-z 0-9 . _ : / # -`). Keys, not positions, identify items: reordering a document changes nothing. |
| B3 | **Ownership.** A source belongs to exactly one project (`UNIQUE (provider, locator)`). Importing it into another project is refused `source-owned-elsewhere`. A document may name the repository it is for (`repository`, a repository identity); if it does, it must be the project's own repository (`repository-mismatch`; `repository-unbound` when the project has none). |
| B4 | **Revisions.** A document carries the source's revision and each item its own (non-negative integers that only grow at the source). A document older than the last imported one is refused whole: `stale-document`. Per item: an older revision than stored is `stale-revision` and changes nothing; the same revision with different content is `revision-reused` (conflict) and changes nothing; the same content is `unchanged` (a newer revision with the same content is recorded, nothing else). |
| B5 | **Idempotency.** Importing the same document again creates and changes nothing (every item `unchanged`). Two imports of one source are serialized (table locks) and the unique keys make a duplicate impossible. |
| B6 | **Updates never overwrite a person's work.** A newer revision with new content updates the task (title, acceptance, dependencies) only while it is still `proposed` and has not been edited in Lockstep since the import wrote it. Otherwise the item is refused `locally-edited` or `locally-progressed`, and the task is left exactly as it is. Items missing from a later document are reported `absent`; nothing is deleted. |
| B7 | **Blockers.** An item's blockers are keys of the same source. A blocker that is neither in the document nor imported before is `dangling-blocker KEY`; an item blocked by a refused item is `blocker-refused KEY`; items on a blocker cycle are `blocker-cycle`; a self-block is `blocker-self`; more than 20 is `too-many-blockers`. Such items are **not imported** (an edge is never silently dropped, which could make work schedulable early). Resolved blockers become task dependencies, which the existing readiness rules (C-P3.6 K3) and the Scheduler already honour. |
| B8 | **Acceptance provenance.** Acceptance arrives as criteria, each with an optional source reference. The task's acceptance text is the criteria rendered one per line (`- text (ref)`); the exact criteria, with their references and the item revision they came from, are kept in `lockstep_task_sources`. |
| B9 | **Source authority is not execution authority.** The format has no state, priority, assignee or approval field, and a document with any unknown key is refused (`unknown-keys`). Every imported task is created `proposed` at Normal priority. Only a person's existing actions (mark ready, hand over, under an enabled project) lead to a Work Order. Nothing in an import creates a Work Order, a schedule decision, a claim, a transaction or a Work Unit. |
| B10 | **Same engine.** An imported task, once a person marks it ready, is handed over by the unchanged `admitBug` and becomes the same Engineering Work Order shape an internal task does. A standalone internal task stays valid with no source and no plan. Plan-derived work (P6.4) will enter by this same path (source kind recorded in the provider vocabulary then; not in this contract). |
| B11 | **Export.** A project's backlog exports as a valid canonical document (provider `canonical`, locator `lockstep:project/<id>`), one item per task: key = task id, revision = task revision + Ticket revision, title, acceptance as one criterion per non-empty line, each referencing `lockstep:task/<id>`, blockers = its
dependencies. No state or authority is exported. Importing an export into another project creates proposed copies with provenance. |
| B12 | **Provider adapter boundary (D6-SOURCE).** A read-only Jira adapter converts a Jira REST v2 search response (`issues[].key`, `fields.summary`, `fields.updated`, `fields.description`, `fields.issuelinks` of type `Blocks` with an `inwardIssue`) into a canonical document, offline, from a file. It reads only those fields; everything else in the provider's data is ignored and cannot authorize anything. It never contacts Jira. **Live Jira/Shortcut intake: NOT_RUN** (no owner-authorized connection). A Shortcut adapter is not built here (NOT_BUILT; the canonical format covers it). |
| B13 | **Audit.** Each accepted import records one immutable row in `lockstep_backlog_imports`: source, document digest (SHA-256 of the bytes), document revision, counts, and the rendered decision. A refused document records nothing. |
| B14 | **Operator interface.** `lockstep backlog import --project PROJECT [--jira LOCATOR] FILE` prints the decision; `lockstep backlog export --project PROJECT` prints the document. No web route is added in P6.1 (the command center is P6.2). (Text corrected by R-P6.1 to the syntax the code and Operator Guide use.) |

### Clarifications and deviations recorded by the review (R-P6.1, `review.md`)

- B5: a repeated import creates no task, Ticket or provenance row; each accepted import still records its one B13
  audit row.
- B7: an item blocked by a refused item that *was imported before* is not refused (its task exists). Cycles are
  checked against the project's dependencies **as they stand** (a person's additions and removals included, paths
  through the person's own tasks followed); only the items that would close a cycle are refused `blocker-cycle`.
- B11: an imported task whose acceptance is unchanged exports its original criteria; an export of more than 500
  tasks is refused `too-many-items`.
- B12: the Jira file must be a complete search result (`startAt` 0, `total` not more than the issues it holds).
- **Deviation:** "dependency origin and dependency kind" (handoff §5) is represented only as provenance (the
  source's blockers in `lockstep_task_sources`); task dependencies stay untyped technical edges (C-P3.6). Typed edge
  kinds come with the Master Plan graph (P6.4, DG-08 §3.2).
- Migration 22 also refuses a provenance row joining a task of one project to another project's source.

### Document format (`lockstep-backlog`, version 1)

```json
{"format":"lockstep-backlog","version":1,
 "source":{"provider":"canonical","locator":"caesura-notes"},
 "revision":7,
 "repository":"<optional repository uuid>",
 "items":[{"key":"CAE-1","revision":3,"title":"…",
           "acceptance":[{"text":"…","ref":"CAE-1 §AC"}],
           "blockers":["CAE-0"]}]}
```

At most 500 items; a repeated key refuses the document (`duplicate-key`). Titles and acceptance follow the task rules
(C-P3.6: title 1–200, acceptance at most 4000 rendered).

### Decision rendering

`lockstep-backlog-import 1`, then `source PROVIDER LOCATOR revision N`, then one line per item in document order:
`item KEY created|updated|unchanged|refused CODE [DETAIL]`, then `absent KEY` lines in key order. Pure and
deterministic (Kernel).

## 2. Typing

- Kernel (pure): `Lockstep.Kernel.Backlog` — `SourceProvider`, `SourceLocator`, `SourceKey`, `SourceRevision`,
  `SourceIdentity`, `Criterion`, `BacklogItem`, `BacklogDocument`, `StoredItem`, `LocalCondition`, `ItemOutcome`,
  `ItemRefusal`, `DocumentRefusal`, `decideImport`, `renderImportDecision`, `itemContentText`, `acceptanceText`.
- Identity: `BacklogSourceId` (UUID newtype, `Lockstep.Kernel.Identity`).
- Fleece schema for the document: `Lockstep.Application.BacklogDocument` (decode and encode from one schema).
- Persistence: `Lockstep.Persistence.Backlog` (Orville tables over migration 22).
- Application: `Lockstep.Application.Backlog` (`importBacklog`, `exportBacklog`), `Lockstep.Application.BacklogJira`.
- No column name contains `plan` or `phase` (the frozen C-P4.1 ExecutionTest asserts this).

## 3. Verification (to be frozen)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/BacklogTest.hs` | unit, pure | B2, B4, B6, B7, rendering, B9 (no outcome grants state) |
| `test/unit/Lockstep/Application/BacklogDocumentTest.hs` | unit | document decoding: unknown keys, bounds, round trip; the Jira fixture conversion (B12) |
| `test/integration/Lockstep/BacklogTest.hs` | integration: real PostgreSQL | B1, B3, B4, B5, B6, B7, B8, B9, B10, B11, B13 |
| `test/fixtures/backlog/jira-search.json` | fixture | B12 |
| `test/unit/Main.hs`, `test/integration/Main.hs` | runners (additive) | registration |

Mandatory cases from the handoff §5 and where they are:

| Handoff case | Test |
|---|---|
| Repeated imports create no duplicate canonical items | integration "importing the same document twice…" |
| Stable source identifiers survive reorderings | unit + integration "reordered" |
| Stale source revisions cannot overwrite newer data | unit + integration "stale" |
| Missing or dangling blockers are reported | unit + integration "dangling" |
| Conflicting repository/source ownership is refused | integration "owned elsewhere", "repository" |
| Imported acceptance criteria retain provenance | integration "provenance" |
| Untrusted external fields cannot authorize execution | unit (decoder), integration "proposed, nothing scheduled" |
| A standalone internal Ticket remains valid without a Master Plan | integration "internal task" |
| A planned Subphase and an internal Ticket enter the same execution engine | integration "same Work Order shape" (an imported task stands for source-derived work until P6.4 adds plan-derived tasks through this path; recorded as a limitation) |

## 4. Freeze record

- Frozen 2026-11-14 by the single writing agent (Implementer), on `phase-6` after `6589fe2` (uncommitted stubs; the
  freeze commit carries these files with the stubs).
- Frozen files (formatted with `scripts/format`, `hlint`: no hints, then hashed with `shasum -a 256`):

  | File | sha256 |
  |---|---|
  | `test/unit/Lockstep/Kernel/BacklogTest.hs` | `47abba339307c6e287c9b79b91ae8b316a1d3630c822478cd9a9382e53b7a58c` |
  | `test/unit/Lockstep/Application/BacklogDocumentTest.hs` | `525555d5623c7343f40c2e2d45f2b9aa3fb600bead0350dabc3cc21302c399b4` |
  | `test/integration/Lockstep/BacklogTest.hs` | `2e659a12f875522a5d5cba62ffb5e3a7dcb480c752aca59383b74f370180a7c5` |
  | `test/fixtures/backlog/jira-search.json` | `14bf6c81d764e89930266fb2173fdcb0f828ed6ff5408014febf50a31dbdd0b8` |
  | `test/unit/Main.hs` (shared runner) | `5c0d41c38f4b603f79aa2c49420afa1e8633f5cb595a304ddee97ad215c495b1` |
  | `test/integration/Main.hs` (shared runner) | `a8fba6032a5c0f499e974cd4a5f8c90c87fda188764dad2840caf911e8b88200` |

- Baseline against the stubs (migration 22 present; Kernel, document, adapter and application functions stubbed):
  unit **31 of 36 fail** (the 5 passing cases are the smart constructors and empty acceptance, already real);
  integration **14 of 14 fail**, each at the import itself after a working setup (migration, projects, enablement)
  — `.local/evals/phase-06/p61-baseline-unit-2.log`, `p61-baseline-integration-2.log`. The first baseline
  (`…-unit.log`, `…-integration.log`) preceded two edits to the tests (one assertion removed whose library
  behaviour was unverified — Fleece on `3.5`; one SQL comparison made explicit); the rerun is the recorded one.

## 5. Allowed paths

New: the files in §2 and §3, `docs/gates/P6.1/**`. Changed: `src/Lockstep/Kernel/Identity.hs` (one identity),
`src/Lockstep/Persistence/Migrations.hs` (append migration 22), `src/Lockstep/Foundation/Cli.hs` and
`app/lockstep/Main.hs` (the `backlog` commands), `package.yaml`/`lockstep.cabal` (module lists), the two test
runners (additive), `docs/OPERATOR_GUIDE.md`.

## 6. Budget, stop, rollback

At most 3 attempts per failing frozen test, then stop and report. No provider call, no external connection, no
host change. Rollback: the branch; migration 22 is additive (three new tables).
