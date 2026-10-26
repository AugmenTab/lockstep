# Contract — P3.6 Work intake and organization

- Contract ID: `C-P3.6@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.6; PRD v0.3 FR-UX-06 (with FR-WRK-03/04/09); Plan v0.3 §4 P3.6
  ("basic task CRUD, priority/dependency editing, honest readiness, persisted changes; no
  execution on Ticket creation"; verification "real browser + DB restart; stale edit, blocked
  high-priority task, duplicate receipt, no implicit execution"); C-P2.2 (the Ticket lifecycle,
  unchanged); C-P3.5 (projects).
- Writer: the single writing agent (Implementer, manual).
- Scope: tasks inside projects. Profiles and eligibility (P3.7), decisions (P3.8), activity
  (P3.9) and any execution (Phase 4) are **not** here.

## 1. What P3.6 delivers

1. **Tasks in a project.** On a project's page a person adds a task in their own words (what needs
   doing, and what "done" looks like), sets how much it matters (High, Normal, Low) and which other
   tasks of the project must be finished first. They can edit all of it later.
2. **Honest readiness.** Every task says in plain words where it stands: not yet ready to work on,
   ready to work on, waiting for named tasks, blocked (with the reason), unable to start because a
   task it needs was canceled, finished, or canceled. A blocked task stays blocked whatever its
   priority; the project page names the most important task that is ready.
3. **Durable, typed changes.** Every change is one typed operation with its revision: a stale edit
   is refused and changes nothing; a repeated submission creates nothing new. Everything survives a
   restart.
4. **No execution.** A task is a C-P2.2 Ticket. Creating, accepting or editing a task creates no
   Work Order, schedules nothing and runs nothing; the page says that running work arrives later.
   A task can be organized in a project that has no folder yet.

## 2. Decisions

| # | Decision |
|---|---|
| K1 | **Tables** (migration 14). `lockstep_project_tasks`: `ticket_id` (primary key, references `lockstep_tickets`), `project_id` (references `lockstep_projects`), `creation_key` unique (the C-P1.5 key rule), `acceptance` 0–4000 characters (new lines and tabs allowed), `priority` 0–999, `revision` from 1, `created_at`, `updated_at`. `lockstep_task_dependencies`: (`task_id`, `depends_on`), both tasks, primary key on the pair, never a task on itself. The Ticket keeps its title, state and events exactly as C-P2.2 stores them. |
| K2 | **Operations** (`Lockstep.Application.Tasks`), each one transaction under a lock on the project's tasks: `createTask` (creation key, project, title, acceptance, priority, dependencies) makes the Ticket (event 1, `Proposed`, Human) and the task row together; `editTask` (expected task revision; title, acceptance, priority, dependencies) — a changed title is a C-P2.2 `TicketRevised` event in the same transaction; `decideTask` (expected Ticket revision; `ready`, `block REASON`, `unblock`, `cancel`) is the C-P2.2 `decideTicket` with principal Human, the cancel signoff naming the application session; `listTasks` (one project) and `findTask`. A repeated creation key returns the task it created. A stale task revision or Ticket revision is refused (`stale-revision`) and changes nothing. |
| K3 | **Rules.** Title 1–200 characters after trimming, no control characters (the C-P2.2 rule); acceptance as K1 after trimming, `\r\n` written as `\n`; priority **High 800, Normal 500, Low 200** (a stored value of 700 or more reads as High, 400 or more as Normal, else Low); dependencies only on other tasks of the same project, never the task itself, never a cycle (`dependency-cycle`), at most 20. |
| K4 | **Readiness** (pure, `Lockstep.Kernel.Task`), from the Ticket state, the block reason and each dependency's title and state, in this order: canceled → *Canceled*; done → *Finished*; blocked → *Blocked: reason*; any dependency canceled → *Cannot start: … was canceled*; proposed → *Not yet ready to work on*; any dependency not finished → *Waiting for …*; ready → *Ready to work on*; any other state → *Being worked on*. The project's **most important ready task** is the highest-priority *Ready to work on* task (then the oldest): a higher-priority task that is blocked or waiting is never chosen. |
| K5 | **No execution.** No P3.6 code path calls `createWorkOrder`, the scheduler, the executor or the reconciler. *Ready to work on* means a person decided it can be worked on; the page says "Nothing runs it yet; that arrives in a later update of Lockstep." |
| K6 | **Pages.** The project page lists its tasks (most important first, each a link with its readiness) and links **New task** (`/app/projects/<id>/tasks/new`). `/app/tasks/<id>` is one task: its words, its readiness, an edit form (title, what done looks like, priority, depends on: a checkbox per other task of the project) and the actions its state allows (**Mark as ready to work on**, **Block…** with a reason, **Unblock**, **Cancel task…**). The **Tasks** section is an overview across projects with links only (the C-P3.4 rule for unbuilt sections still holds for it). Fragments: `/app/fragments/task-new/<project id>`, `/app/fragments/task/<id>`. Forms post to `/app/api/projects/<id>/tasks`, `/app/api/tasks/<id>/edit` and `/app/api/tasks/<id>/decide` (session header, Origin, up to 16 KiB) and answer `200` with the page to show (`X-Lockstep-Path` for a task page), or the form again with what was typed and the reason in words. No Ticket, Work Order, Engineer or scheduler word on the ordinary path; Advanced details keep the exact ids, states and revisions. |
| K7 | **Plain words** for every refusal: `title-empty`, `title-too-long`, `title-control`, `acceptance-too-long`, `acceptance-control`, `unknown-priority`, `unknown-dependency`, `dependency-self`, `dependency-cycle`, `too-many-dependencies`, `stale-revision`, `unknown-task`, `unknown-project`, `not-allowed-now` (the C-P2.2 transition refused), `reason-empty`. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/TaskTest.hs` | unit | title, acceptance and priority rules; priority reading of stored values; readiness in K4's order for every state; the most important ready task never a blocked or waiting one; cycle detection; plain words for every K7 code and every readiness, with no Ticket, Work Order, Engineer or scheduler vocabulary |
| `test/integration/Lockstep/TasksTest.hs` | integration: real PostgreSQL, the operations in-process | create (Ticket `proposed` with one event, task row, in a project without a folder); rules first, nothing created; repeated creation key; edit (title as a `TicketRevised` event, other fields, task revision); stale edit refused, nothing changed; dependencies (other project, self, cycle, unknown refused); decide ready/block/unblock/cancel with the Ticket revision, stale and illegal ones refused; readiness from stored facts; the most important ready task skips a blocked high-priority one; **no Work Order, schedule decision, job or effect is ever created** |
| `test/integration/Lockstep/TasksPageTest.hs` | integration: real service | the project page's task list and New task link; the new-task form; session and Origin required; the task page and its address; edit with an old revision explained, nothing changed; actions shown only when allowed; escaping; the Tasks overview has links only and says "later update"; 404s; 16 KiB limit |
| `test/integration/Lockstep/TasksBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen), real service against a real database | sign in → a project → two tasks, one depending on the other → mark ready → block the high-priority one → the page names the other as the most important ready task → **the service restarts** → the same states and words after reload → keyboard only for one form |

Page wording and ids the tests rely on: the project page's `#new-task` link, "Most important task
ready to work on: …", "Blocked: …", "Waiting for: …"; the task form's "What needs doing",
`#task-title`, `#task-acceptance`, the `priority` radios `#priority-high`, `#priority-normal`
(default), `#priority-low`, `depends_on` checkboxes, `#create-task`; the task page's
`#task-ready` ("Mark as ready to work on"), `#block-reason` and `#task-block` ("Block…"),
`#task-unblock` ("Unblock"), `#task-cancel`, `#back-to-project`, hidden `revision` (edit) and
`ticket_revision` (actions), "Nothing runs it yet", "changed since this page was shown", "Say why
it is blocked"; readiness words "Not yet ready to work on.", "Ready to work on.", "Canceled.".

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| Frozen files (P3.6 and earlier) | digests unchanged | §4, C-P3.5 §4, C-P3.4 §4 |
| `scripts/check --integration` | format, lint, build, unit (773), no-live-model guard PASSED; integration 341 of 343 PASSED, the 2 failures being the known C-P3.4 `HandoverTest.hs` defect | `check-integration.log` |
| C-P3.6 groups | unit 10 of 10; tasks 8 of 8 (no Work Order, schedule decision, job, effect or work unit is ever created); pages 8 of 8; the real-browser journey across a service restart (project → two tasks with a dependency → ready → a blocked high-priority task → the most important ready task named → restart → the same words → a form submitted with the keyboard) PASSED | `check-integration.log` |

The first implementation run failed twice on the implementation, never on a test: the project
page named the most important ready task above the list (now below it, so the list leads in
priority order), and attribute values escaped quotes and ampersands but not angle brackets, so a
typed title appeared unescaped inside the edit form's `value` (now escaped everywhere through one
helper, `Lockstep.Web.Fragment.attr`).

Implementation notes (decisions within the design, recorded here):

- `Lockstep.Application.Ledger` gains `createTicketIn`, `reviseTicketIn` and `ticketFactsIn`: the
  bodies of `createTicket` and `reviseTicket`, and a read of the replayed state, inside the
  caller's transaction. `createTicket` and `reviseTicket` behave exactly as before.
- The cancel signoff (C-P2.2 requires one) reads "canceled in the application (application)": the
  application session authenticated the person; no token or session id is recorded in it.
- `too-many-dependencies` counts the submitted list before repeats are removed.

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the task operations and pages were
implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/TaskTest.hs` | `7d66cbbd65b88fb6f8a39b17cef4fee738cf71337bd5dae5da8b3f056467b950` |
| `test/integration/Lockstep/TasksTest.hs` | `181cb31396381fe46a32c53de8f411cc1168320eb6bc9fa04cadc7a4bd4266ca` |
| `test/integration/Lockstep/TasksPageTest.hs` | `aa2762294658439742b3cff52c31c5d298b9dd0203a1ccdc242103d8856f4120` |
| `test/integration/Lockstep/TasksBrowserTest.hs` | `29ccfddf9009a44a127ca56db87aa0fc15f44772f53c1bd554dc62a0046687b0` |
| `test/unit/Main.hs` (runner, additive) | `31899581befb95a0b9e0dc00ee9cac7ff21748602f6f9519c1c41a6e685fb79b` |
| `test/integration/Main.hs` (runner, additive) | `7c680de67d42f4f3252ce2da2b29c57a3bb7dfbe92addb7aaab6b0d28f2884eb` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- Unit baseline against type-only stubs (`prefreeze-unit-baseline.log`): 10 of 10 new cases fail.
  The pure task rules were then implemented before the freeze (`prefreeze-unit-after-rules.log`,
  10 of 10 pass), because `scripts/check` stops at the first failed step and the integration
  baseline could not run otherwise.
- `scripts/check --integration` against stubbed task operations and the unchanged pages
  (`prefreeze-integration-baseline.log`): format, lint, build, unit (773) and guard pass; 19 of 343
  integration cases fail: the 2 known `HandoverTest.hs` cases and all 17 new ones. Each new failure
  was read for its reason: the stubbed operations ("not ready"), 404 for the new pages and routes,
  no New task link on the project page, no `#new-task` in the browser. The fixtures ran (migrated
  databases, projects through C-P3.5, the real service and the browser up to the project page).
- Found and fixed before the freeze: one fourmolu layout in the task rules; the test's creation
  keys were again shorter than the 16-character key rule (the C-P3.5 lesson, repeated), so most
  cases failed in the fixture — fixed and the baseline run again.
