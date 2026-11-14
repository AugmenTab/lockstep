# Contract — P6.3 Human Inbox and bounded Planner clarification

- Contract ID: `C-P6.3@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-06.md` §7 (P6.3); PRD v0.4 FR-HUM-03; Plan v0.4 §4 P6.3; Bible v2.3 B23-14.
- Basis: `phase-6` after `081201f` (P6.2 remediation: full check PASSED, unit 944/944, integration 605/605).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

C-P4.3 already gives Human Requests their identity, revision, kind, typed choices, ordered messages, idempotency
keys, payload digests, and the rules: an agent is never a principal; only a Human decides; a decision names an
offered choice at the current revision; a clarification never decides; a closed request takes nothing more. The
engine opens a decision request at every halt (C-P4.15), and the task page answers it (C-P4.16). Nothing yet lets a
person **ask** about a request, nothing ever **answers** such a question, no page lists open requests **across
projects**, and the choices are not explained by their **consequences**. P6.3 adds exactly those, reusing the C-P4.3
conversation as the only record and the Supervisor as the only authority.

| # | Decision |
|---|---|
| I1 | **The Human Inbox is the Decisions section.** Below its existing ledger decisions, it lists every open Human Request across projects: the project, the task (a link to its page, where it is answered), the question, the step it stopped at, and each choice with its consequence. The section keeps C-P3.8's rule: no form and no button there (`DecisionsPageTest`); answering and asking happen on the task page. No new nav entry (the frozen 7). |
| I2 | **Consequences of each choice** (`Lockstep.Kernel.Inbox.choiceConsequence`), from the Supervisor's own vocabulary: `retry` — what runs again (`retryOperation` for the stage, C-STAB-1 S2.4); `stop` — the fix stops, nothing more runs, the work branch is kept, nothing is published; `replan` — the Planner looks for the cause again; `accept-non-reproduction` — the fix goes on without a separate reproduction and its tests must still fail because of the bug. A choice with no known consequence says so ("Lockstep cannot describe what this choice does"); it is never left blank. |
| I3 | **Asking.** On the task page, under an open request, the person may ask a question: a C-P4.3 `HumanSays` message at the request's revision, behind an idempotency key, through `POST /app/api/requests/<id>/questions` (session and origin required). It never answers or resumes anything; a closed request refuses it (`request-closed`), a stale page refuses it (`stale-revision`). |
| I4 | **Answering a question: one bounded, read-only Planner invocation**, by the engine worker (a new phase after the transactions, `Lockstep.Application.Clarification.answerClarifications`). A question is pending when it is the request's latest message, the request is open, and no clarification was attempted for that message. The Planner runs read-only (C-P4.5 A5 profile), in an empty workspace (no repository), with a context of the request (question, evidence, choices with consequences), its conversation, and the task's title and acceptance; the answer is a new answer kind `clarification` (`{"kind":"clarification","text":…}`, 1–4000 characters). The Supervisor posts it as a C-P4.3 `PlannerSays` message (principal Supervisor, evidence `planner-invocation <id>`). |
| I5 | **Clarification cannot authorize.** A `PlannerSays` message changes nothing but the conversation (C-P4.3 H2); the request stays open; the transaction stays halted; only the person's `HumanDecides` resumes it. Whatever the Planner writes ("I approve", "retry") is text. |
| I6 | **Bounded and idempotent.** Each attempt is one row in a new table `lockstep_clarifications` (request, the message sequence it answers, outcome, the answer's digest), unique per (request, message): a second pass, a second worker or a replayed event cannot run it twice. At most **3** attempts per request; beyond that a question is left unanswered and the page says so. Without a coding helper the attempt ends `no-helper` and nothing is posted (no text is ever invented). A failed run ends `failed` with its code; nothing is posted. |
| I7 | **Restart.** An attempt found unfinished when a pass begins (the worker was stopped mid-run) is finished `uncertain`: it is **never run again** by itself and nothing is posted; the person may ask again. |
| I8 | **Unrelated work continues.** The clarification phase runs after the transactions in each pass and touches no transaction; a question pending on one fix does not hold any other fix. |
| I9 | **What a request carries** (handoff §7): identity, project, task, Work Order, Contract digest (C-P4.3), question, evidence, legal actions (choices), consequences (I2), state, idempotency; the plan revision is "no approved plan" until P6.4. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Inbox` (`choiceConsequence`); `Lockstep.Kernel.Roles` gains `AnswerClarification` (a checked
  text) with its rule for the Planner.
- Effects: `decodeAnswer` gains kind `clarification`; the Planner's instructions gain the clarification text (plain and
  capsule).
- Persistence: migration 23 `lockstep_clarifications`; `Lockstep.Persistence.Clarification`.
- Application: `Lockstep.Application.Clarification` (`answerClarifications`), `Lockstep.Application.Inbox`
  (`inboxEntries`), the worker phase.
- Web: the Decisions section's inbox part; the task page's conversation and question form; the question route.

## 3. Verification (to be frozen)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/InboxTest.hs` | unit | I2; the clarification answer rule and decoding |
| `test/integration/Lockstep/InboxTest.hs` | integration: real PostgreSQL, Git, processes, scripted roles | I1 (entries), I3–I8, the handoff §7 list |
| `test/integration/Lockstep/InboxPageTest.hs` | integration: the real service over HTTP | I1 (section, no form), I3 (route, session, origin), the conversation on the task page |

Handoff §7 mandatory tests: authenticated decision succeeds once; duplicate reply idempotent; stale revision refuses;
forged principal refuses; clarification cannot grant permission; conflicting simultaneous requests stay distinct;
late response cannot reauthorize a closed request; session expiration preserves pending requests (the request is
durable; S4 covers the browser); unrelated eligible work progresses; browser actions cannot skip the Supervisor.

## 4. Freeze record

- Frozen 2026-11-14 by the single writing agent, on `phase-6` after the DG-08/P6.10a records commit, with migration
  23 and its persistence module real, and stubs for `choiceConsequence`, the clarification answer rule and decoding,
  `answerClarifications`, `inboxEntries` and `askQuestion`; no web change yet.
- Frozen files (`scripts/format`, `hlint`: no hints, `shasum -a 256`):

  | File | sha256 |
  |---|---|
  | `test/unit/Lockstep/Kernel/InboxTest.hs` | `e8785ec8595dcb06bd31e8f25c4d10d6e6194f19b225ca387383b2a4bb586310` |
  | `test/integration/Lockstep/InboxTest.hs` | `55809fa3d1849045b445d55f6c0103f9f380595bafeee51bc04f1f5cc50dafbb` |
  | `test/integration/Lockstep/InboxPageTest.hs` | `070c5c0dc5b95c3980710de2768f5a3f46f5891a26f1256bb18ff3c539c269f2` |
  | `test/unit/Main.hs` (shared; supersedes earlier digests, additive) | `1119b5a57e2fdaaebfd363005568f97f30d9b783b953b9eef83f8d423ce33f31` |
  | `test/integration/Main.hs` (shared; supersedes earlier digests, additive) | `af7adfac15a5c353e0b83dfc33198eef21be592187495a729a36181627aeb9ee` |

- Baseline: unit **5 of 6 fail** (the passing case pins the constant `maxClarifications = 3`); integration **12 of 12
  fail**, each at the missing feature after a real halt and open request were reached (the `authority` case passes
  its pre-existing C-P4.3 refusals, then fails at the stale question). Logs `.local/evals/phase-06/p63-baseline-*.log`.

## 5. Allowed paths

New: the files in §2/§3, `docs/gates/P6.3/**`. Changed: `Kernel/Roles.hs`, `Effects/Roles.hs`,
`Effects/Provider/Claude.hs`, `Persistence/Migrations.hs` (append 23), `Application/EngineWorker.hs`,
`Web/App.hs`, `Web/Routes/App.hs`, `Web/Routes/Params.hs`, `Web/DecisionPages.hs`, `Web/ExecutionPages.hs`,
the runners, `docs/OPERATOR_GUIDE.md`.

## 6. Budget, stop, rollback

At most 3 attempts per failing frozen test. No provider call (scripted Planner only); a live clarification is
NOT_RUN. Rollback: the branch; migration 23 is additive.
