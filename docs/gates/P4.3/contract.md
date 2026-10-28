# Contract — P4.3 Durable human requests and their conversations

- Contract ID: `C-P4.3@v1`
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.3 ("the narrow durable Human Request / Conversation model from Bible
  v2.2 §13.3. Persist ordered messages, exact request identity, authenticated principal evidence,
  relevant revisions and typed clarification responses. A clarification is **not** permission or a
  binding approval. Test crash/restart, replay, stale revisions and identity mismatches. Do not
  implement email, an unrestricted chatbot or a full Human Inbox"); Bible v2.2 insert 03 (§13.3); PRD
  v0.3 FR-HUM-01 (P4.3 scoped persistence), FR-HUM-02; Plan v0.3 §5 P4.3 and its dependency note ("the
  narrow durable core … must not … turn clarifications into binding permissions"; "no model-backed chat
  UI need block P4.4"); C-P2.2 T1–T3 (principals: an `Agent` is never accepted; an agent's claim enters
  only as a Supervisor-submitted observation); C-P1.5 (idempotency keys); C-P3.8 (receipts pattern).
- Writer: the single writing agent (Implementer, manual).
- Scope: the durable record and its rules, reachable through typed application operations. **No page,
  no email, no model invocation, no inbox.** P4.15 consumes binding answers through typed Supervisor
  commands; P4.16 shows them. Nothing here changes a Work Order, a Ticket or any effect.
- Open-gate check: depends on P3.8, P4.1 and the Phase 2 store; no `OPEN` design gate.

## 1. What P4.3 delivers

1. **A Human Request** is a bounded, source-linked question to a person about one Work Order: the
   Engineer, the Work Order, the Contract digest when one exists, the evidence it rests on, the
   authority it asks for, and its current revision. It is either a **clarification** (information only)
   or a **decision** (a fixed, finite list of choices).
2. **A Conversation** is its durable, ordered list of messages: people's messages, the Planner's
   answers (submitted by the Supervisor, never by an agent directly), revisions of the request, a
   withdrawal, and at most one **binding answer**. Every message records who sent it, through which
   channel, and the request revision it was written against.
3. **A clarification is not a decision.** Only a person's binding answer to a decision request, naming
   one of its choices at its current revision, is binding; and even that is only recorded here. Nothing
   in P4.3 applies it.
4. **Exactly once, across restarts.** Each message is one transaction with an idempotency key; the
   same request again returns the stored message; other content under the same key is refused. A stale
   revision, a second binding answer, an agent, or a sender in the wrong role is refused and changes
   nothing.

## 2. Decisions

| # | Decision |
|---|---|
| H1 | **Requests** (`Lockstep.Kernel.Conversation`, pure). `RequestKind = ClarificationRequest \| DecisionRequest (NonEmpty Choice)`; a `Choice` name matches `^[a-z][a-z0-9-]{0,39}$`, at most 10 per request, no repeats (`invalid-choices`). Question, evidence and requested authority: 1–4000 characters after trimming, new lines and tabs allowed, no other control character (`text-empty`, `text-too-long`, `text-control`). A new request is `Open` at revision 1. States: `Open`, `Answered choice`, `Withdrawn`. |
| H2 | **Inputs and who may give them** (`stepRequest`), in this check order: principal `Agent` → `agent-assertion`; the request not `Open` → `request-closed`; the input's expected revision differs from the current one → `stale-revision`; then: `HumanSays text` (Human only), `PlannerSays text` (Supervisor only, on behalf of a Planner invocation), `HumanDecides choice text` (Human only; a clarification request → `not-a-decision`; a choice not offered → `unknown-choice`; the request becomes `Answered`), `Revise question` (Supervisor only; revision + 1), `Withdraw reason` (Human or Supervisor; `Withdrawn`). Any other principal for an input → `not-authorized`. Text rules as H1. Every accepted input appends exactly one message. |
| H3 | **Senders** (`Lockstep.Application.Conversation`): `SenderHuman channel` (principal Human; evidence `<channel>-session`, channels `application` and `cli`), `SenderPlanner invocation` (principal Supervisor; evidence `planner-invocation <id>`, channel `engine`; the invocation id 1–64 of `[A-Za-z0-9_-]`), `SenderSupervisor` (principal Supervisor, evidence `supervisor`, channel `engine`), `SenderAgent label` (principal Agent; always refused, recorded nowhere). No request field can name a principal; the sender is a typed argument. |
| H4 | **Storage** (migration 19). `lockstep_human_requests`: `id` uuid; `idempotency_key` unique (C-P1.5); `payload_digest`; `work_order_id` → work orders; `engineer_name`; `contract_digest` (64 hex or null); `kind` (`clarification`, `decision`); `choices` (comma-joined, empty for a clarification); `question`; `evidence`; `requested_authority`; `revision` ≥ 1; `state` (`open`, `answered`, `withdrawn`); `answer` (the choice, set exactly when answered); `created_at`, `updated_at`. `lockstep_conversation_messages`: `id`; `request_id` → requests; `sequence` ≥ 1, unique per request; `idempotency_key` unique; `payload_digest`; `kind` (`opened`, `human`, `planner`, `decision`, `revision`, `withdrawal`); `principal`; `sender_evidence`; `channel`; `request_revision` (the revision it was written against); `body`; `choice` (set exactly for `decision`); `recorded_at`. Messages: UPDATE, DELETE, TRUNCATE refused by trigger. A request row changes only together with the message that changes it, in one transaction, under a row lock. |
| H5 | **Operations**, each one transaction: `openRequest key sender request` (Supervisor only; the Work Order must exist; appends message 1 `opened` with the question); `postMessage key requestId expectedRevision sender input`; `conversation requestId` (the request and its messages by sequence); `openRequests` (the `Open` ones, oldest first). Replay: a key already stored with the same payload digest returns the stored result and writes nothing; with another digest → `key-conflict`. Payload text (pure, `requestPayloadText`, `messagePayloadText`): `lockstep-human-request-v1` / `lockstep-conversation-message-v1`, then each field on its own line, free text escaped (`\`, `"`, new line). Unknown request → `unknown-request`; unknown Work Order → `unknown-work-order`; malformed contract digest → `invalid-contract-digest`. |
| H6 | **Nothing is applied.** No P4.3 path changes a Work Order, Ticket, intent, schedule or Profile, or invokes a model. A binding answer is a durable, exact record for P4.15 to consume through a typed Supervisor command. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/ConversationTest.hs` | unit | H1 text and choice rules; H2 check order and every refusal; who may give each input; a clarification never answers; a decision answers once; revise raises the revision and makes older answers stale; withdraw closes; payload texts exact and each field changes them |
| `test/integration/Lockstep/ConversationTest.hs` | integration: real PostgreSQL, in-process, a Work Order made through C-P2.5 | open (message 1); a person asks, the Planner (through the Supervisor) answers, the person decides: four messages in order with principals, evidence, channels, revisions; replay returns the stored message and writes nothing; other content under a key `key-conflict`; a stale revision after a revision; an agent, the Planner deciding, a person posting as the Planner, a Supervisor deciding: refused, nothing written; a clarification request cannot be decided; a second decision `request-closed`; withdraw; **restart** (a new runtime over the same database): the same conversation, and a replay after it writes nothing; the Work Order, its events and every effect table unchanged by the whole conversation; messages immutable |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| C-P4.3 integration group, targeted | 8 of 8 at the first implementation run | `.local/p43-run1.log` (not committed) |
| `scripts/check --integration` on `0fcb2b9`, clean tree | **FAILED at step 1 (format)**: the frozen unit runner's new import is out of fourmolu's order; steps 2–6 NOT_RUN | `check-integration-0fcb2b9.log` |
| The same with proposed amendment A-P4.3-1 applied temporarily | all six steps PASSED: unit 818 of 818, integration 454 of 454, backup/restore; Kernel boundary and purity scan clean (25 files) | `trial-with-a-p4.3-1.log` |
| Frozen files | restored after the trial; `test/unit/Main.hs` back at its frozen digest; the others never touched | §4 |
| Linux clean clone | (before A-P4.3-1) NOT_RUN: the format step fails by construction | — |
| After A-P4.3-1 (approved 2026-10-28, §4.1): `scripts/check --integration` on the Mac, revision `30e1060` (code identical to `4ee971d`; the tree was dirty only by an untracked P4.2 draft outside the build) | all six steps PASSED: unit 818 of 818, integration 454 of 454, backup/restore | `check-integration-4ee971d.log` |
| Linux clean clone of `30e1060` | format, lint, build, unit 818 of 818, integration 454 of 454 PASSED | `linux-clone-30e1060.log` |

**Status: VERIFIED** at `4ee971d` (amended runner) — Mac and Linux, unit 818/818, integration 454/454.

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the operations were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/ConversationTest.hs` | `9f3ddfb9b7c8ad6729784ef9734fa2e8414872b42aabd901a82042918e5c6004` |
| `test/integration/Lockstep/ConversationTest.hs` | `21ca2b30111a143207b51c3a9dc9954d95cc40e6335c682cfa13b76e4c9fe9cb` |
| `test/unit/Main.hs` (runner, additive) | ~~`ee38476e022283dbd2a60338cf8726b9504688450fdbd49488174e771dda8fcd`~~ → `7e9892b31c2ac908f2fe1fc8e3b0f40628bdb9b3ebf5dcd100606fe114bb6b1e` (A-P4.3-1, §4.1) |
| `test/integration/Main.hs` (runner, additive) | `d6a4bea8d6e1b4b5217594125af3c1cf1f3eb5b9d681b035e8d4f55429547c3e` |

Earlier frozen tests are untouched; the runners only gain lines (one each).

Pre-freeze verification:

- The pure rules (`Lockstep.Kernel.Conversation`), migration 19 and `Lockstep.Persistence.Conversation` were
  written before the freeze; the operations (`Lockstep.Application.Conversation`) were a stub with the final
  types, refusing `not-implemented`. Build (Kernel boundary and purity scan), format and lint clean (5 hlint
  hints in the unit test fixed first).
- Unit (`prefreeze-unit.log`): 818 of 818, the 10 new cases passing on the real pure rules (written together,
  not run against a stub first: the P3.6–P4.1 reason).
- Integration baseline (`prefreeze-integration-baseline.log`): **targeted** to the C-P4.3 group, against the
  stub: 8 of 8 fail, each at the first `openRequest` (`not-implemented`), after the fixture ran (a migrated
  database, a project in a new folder through C-P3.5, the always-on rules, a ready task, a C-P2.5 Work Order).
  Because each fails at its first call, every later assertion was checked against H1–H6 by reading. The rest of
  the suite was qualified at `bd4512b` (446 of 446) and is re-run in full after implementation; P4.3 adds only
  new modules, migration 19 and runner lines.

### 4.1 Amendment A-P4.3-1 (re-freeze)

Approved 2026-10-28 by the owner's adoption of `.local/plans/phase-04_update1.md` (sha256 `4cb620d3…d1f7`,
"A-P4.3-1 — FINAL PLANNER APPROVAL"). Applied exactly as `amendment-request-1.md`: one import line moved.
Digest before checked `ee38476e…dda8fcd`; digest after `7e9892b3…bb6b1e`, equal to the request's. No other
frozen file changed.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Conversation.hs`, `src/Lockstep/Application/Conversation.hs`,
`src/Lockstep/Persistence/Conversation.hs`, the two test files. Changed:
`src/Lockstep/Persistence/Migrations.hs` (append 19), `lockstep.cabal` (generated), the runners
(additive), `docs/gates/P4.3/**`, `docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts Bible
§13.3, C-P2.2 T1–T3 or a frozen test. Rollback: revert the P4.3 commits; migration 19 only adds
tables.
