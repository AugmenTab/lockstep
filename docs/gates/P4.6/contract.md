# Contract — P4.6 The coding transaction: start, basis, discovery, reproduction

- Contract ID: `C-P4.6@v1`
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.6 ("apply the effective Bug Profile to produce source-grounded discovery, bug
  reproduction evidence, scope constraints and a root-cause hypothesis. Missing reproduction must block unless an
  expressly permitted and evidenced non-reproduction path applies. Exit: a bug can be characterized sufficiently
  to support a meaningful Contract instead of coding from an unsupported guess"); DG-06 D-6.6 (missing
  reproduction blocks; only a person's evidence-backed exception); DG-17 (runner, limits, uncertainty never
  replayed); C-P2.2 T1–T3 (principals; an Agent never accepted); C-P4.1 (admission, ownership); C-P4.2, C-P4.4,
  C-P4.5; C-P4.3 (human requests); `engine-design.md` §1–§3a.
- Writer: the single writing agent (Implementer, manual).
- Scope: the transaction aggregate and its first three stages. Candidate tests and later stages are P4.7
  onward (`stage-not-built` until then); acting on a person's answer to a halt is P4.15; pages are P4.16. The
  engine is not yet started by the service. Persistence is in the existing style (owner's decision 2026-10-28).

## 1. What P4.6 delivers

1. **The transaction rules** (`Lockstep.Kernel.Transaction`): stages, states, budgets, who may give each
   input, every halt, the reproduction rule and the choices a person is offered.
2. **Its records** (migration 20): the transaction's head row; immutable records; invocations recorded
   before they run and finished exactly once.
3. **The engine** (`Lockstep.Application.Engine`): start, and one stage per `advance` for basis, discovery and
   reproduction; every halt opens a durable decision request to a person.

## 2. Decisions

| # | Decision |
|---|---|
| T1 | **Rules** (pure). Stages `basis, discovery, reproduction, candidate, challenge-pre, freeze, implement, verify, challenge-post, review, accept`; states `running`, `halted <code>`, `accepted`, `done`, `stopped <code>`. `stepTransaction` check order: `agent-assertion`; `not-authorized` (a person's input — retry, accept-non-reproduction, stop, done — from anyone but a Human; any other input from anyone but the Supervisor); `closed`; then the stage's rule (`illegal-input`). The stage table and budgets are `engine-design.md` §3a (corrections ≤ 2, attempts ≤ 2). A failed or uncertain role, or a Supervisor step that could not be done, halts at its stage (`role-failed <code>`, `uncertain-invocation <code>`, `supervisor-failed <code>`). A halted transaction resumes only by a person's retry (the same stage), accept-non-reproduction (only at `reproduction-missing`), or stop. |
| T2 | **Reproduction** (pure, `reproduces`): the command ran and exited non-zero, not 126 or 127, and its signature appears in its output; a timeout, too much output or a failed launch never reproduces. **Halt choices** (`haltChoices`): `accept-non-reproduction, retry, stop` for `reproduction-missing`, else `retry, stop`. |
| T3 | **Storage** (migration 20): `lockstep_transactions` (one per Work Order, its task, Engineer and folder, state, stage, halt code, counters, basis, branch, later commits and Contract digest, revision; never deleted); `lockstep_transaction_records` (sequence, kind, principal `human`/`supervisor`, stage, JSON body ≤ 4 MiB, its SHA-256; immutable); `lockstep_invocations` (stage, what, runner, adapter, argv, then once: outcome, exit, time, byte counts, digests, the last 2000 characters of each stream; a second finish or any change refused; never deleted). |
| E1 | **Start** (`startTransaction`): for an admitted bug Work Order (C-P4.1) the transaction at `basis`, with a `started` record; the same Work Order again → the same transaction. Refused: `unknown-work-order`, `not-admitted`, `engineer-busy` (the Engineer's one writer holds a running or halted transaction). |
| E2 | **One input** at a time, under the row lock, at the revision the stage started from (`stale-step` otherwise), with the stage's records, an `input` record, and a `halt` record when it halts. |
| E3 | **Advance** (`advance`): a running transaction does one stage; a halted one has its decision request (C-P4.3, Supervisor, choices T2, key from the transaction and its halt record — so it is opened once and opened again with the same identity after a crash); accepted, done and stopped do nothing. |
| E4 | **Cut-short invocations**: found started but not finished at the next advance (a crash or restart): a role's is finished `uncertain` and the transaction halts `uncertain-invocation` (never run again by itself); a command's is finished `interrupted` and the stage runs again. |
| E5 | **Basis**: ownership re-checked (C-P4.1 `ownershipHolds`); `observeBasis` (C-P4.4 G2); the branch `lockstep/<work order>` made at `HEAD` (G3). Any refusal halts with its code. |
| E6 | **Discovery**: the Planner (read-only) on a fresh snapshot of the basis, context: role, stage, the task's title and what done looks like, the basis; recorded `started` before and finished after with its evidence. The answer's citations must name files of the basis and lines they have (`citation-outside-source`); recorded in its answer form (kept as data). No adapter for the Planner → `role-failed no-coding-agent` (no invocation). |
| E7 | **Reproduction**: the discovery's command run by the Supervisor on a fresh snapshot of the basis (runner verification profile, command limits), recorded like an invocation (`adapter supervisor`); T2 decides; the record keeps the command, signature, outcome, exit, both stream tails. No command, or a command that does not reproduce → halted `reproduction-missing`. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/TransactionTest.hs` | unit | T1 every stage in order and Done; principals; reproduction halt and its human exception; baseline classes and corrections; pre-freeze findings; attempts; role and Supervisor failures; closed; names |
| `test/integration/Lockstep/EngineTest.hs` | integration: real PostgreSQL, Git, processes; scripted Planner on the direct runner; a Python repository with a real bug | E1 start, same again, refusals; E5 basis and branch, the person's checkout untouched; a dirty repository halts with one request (retry, stop); E6 the answer recorded with its invocation (runner, adapter, argv, outcome); a citation outside the source halts; E7 reproduced (exit 1, signature) and not reproduced (passing command, no command) with accept-non-reproduction offered; a crashing role and no coding agent; E4 a run cut short, a restart: uncertain, halted, not run again; T3 records and invocations immutable |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| C-P4.6 integration group, targeted | 10 of 10 at the first implementation run | `.local/p46-run1.log` (not committed) |
| `scripts/check --integration` on the Mac, `cbd7394`, clean tree (the P4.4–P4.6 checkpoint) | all six steps PASSED: unit 854 of 854, integration 500 of 500, backup/restore | `check-integration-cbd7394.log` |
| Linux clean clone of `cbd7394` | running | — |

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the engine was implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/TransactionTest.hs` | `0dfe0f7eebc539d27772c49d3927af83d60928ac2b896d54cdbbf11703bf3e1a` |
| `test/integration/Lockstep/EngineTest.hs` | `8035cd9a2c0e978b90eec9f0e7636482378bcee58fe3ae68e04a29424e3d2994` |
| `test/unit/Main.hs` (runner, additive) | `d55cbd2cb6b97ef65f05432aaddc7ea1843e7294ffd499ef1df7edb42e8eb70c` |
| `test/integration/Main.hs` (runner, additive) | `f99d483be8d20a4fbd855b628900f1b0cca85840eba1d34058f51f9cc3e40523` |

Pre-freeze verification (logs in this directory):

- Written before the freeze: the rules (`Lockstep.Kernel.Transaction`), migration 20 and its storage
  (`Lockstep.Persistence.Transactions`). `Lockstep.Application.Engine` was a stub with the final types (nothing
  started or advanced). Build (purity scan), format and lint clean (5 hints fixed).
- Unit (`prefreeze-unit.log`): 854 of 854. The first run caught a defect in the rules written before the freeze:
  accepting non-reproduction was allowed at any halt of the reproduction stage, not only at
  `reproduction-missing`; fixed in the rules (the test was right).
- Integration baseline against the stub (`prefreeze-integration-baseline.log`): **10 of 10 fail** at the first
  engine call (`not-implemented`), after their fixtures ran (project, commit, allowance, task, admission).
- Fixture trial against the draft engine (`fixture-trial.log`): first 8 of 10; the two failures were the test's
  own count queries (the shared helper reads a column named `v`; the queries did not name it), corrected with
  that evidence before the freeze (DG-06 clarification); then **10 of 10**. The stub was put back for this
  freeze commit.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Transaction.hs`, `src/Lockstep/Persistence/Transactions.hs`,
`src/Lockstep/Application/Engine.hs`, the two test files. Changed: `src/Lockstep/Persistence/Migrations.hs`
(append 20), `lockstep.cabal` (generated), the runners (additive), `docs/gates/P4.6/**`,
`docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the P4.6 commits; migration 20
only adds tables.
