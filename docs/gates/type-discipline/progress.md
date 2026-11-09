# Type-discipline remediation — progress record

- Handoff `phase-04_update10` (owner-approved), 2026-11-08.
- Branch `remediation/type-discipline` from `remediation/stack-compliance` `1b4a390` (stack-compliance packet
  `90da1cc` plus the stack-pattern study). Nothing pushed.
- Baseline qualification (stack-compliance packet §8, revision `d695ae8`, code unchanged since): format, lint, build,
  unit **870/870**, guard, integration **571/571**, backup/restore, Linux clone, live checks — all passed.
- References: `docs/architecture/STACK_PATTERNS.md`, `docs/reviews/type-discipline-audit-2026-11-08.md`.

## Increment A — the nine correctness defects (audit §4)

| # | Defect | Correction | Regression evidence |
|---|---|---|---|
| 1 | Profile digest via `show`, 64-zero fallback (`Application/Profiles.hs`) | `Lockstep.Foundation.Digest` (crypton `Digest SHA256`, hex via memory's `convertToBase Base16`); the Kernel's total `contentDigestFromBytes`; `sha256Hasher = Hasher (contentDigestFromBytes . sha256Utf8)`. No fallback exists. | compliance `1.`: NIST vectors; byte-identical to the former `show` output on varied input; round-trips `mkContentDigest` |
| 2 | Revision `Integer` narrowed after only a negativity check (`Application/Command.hs`) | `mkRevision`: range checked on the `Integer` before narrowing; new `RevisionTooLarge` | compliance `2.`: `maxBound` accepted, `maxBound + 1` and 2^64 refused (2^64 wrapped to 0 before) |
| 3 | Migration checksum via crypton's `Show Digest` (`Persistence/Migration.hs`) | `sha256Hex . sha256Utf8` | compliance `3.`: every production migration's checksum equals the `show`-encoded value stored in existing ledgers |
| 4 | Unchecked text stored when its check fails (`Application/Conversation.hs`) | Kernel `stepRequestChecked` returns the H1-checked text; that text is stored. `stepRequest` (frozen signature) is `fst` of it | compliance `4.` |
| 5 | Dummy `"create"` fallback (`Application/Ledger.hs`) | Kernel `workOrderCreatedText`, total; `encodeWorkOrderEvent WorkOrderCreated` uses it | compliance `5.`: encodes and replays as a creation |
| 6 | Empty-string effective digest stored (`Application/Execution.hs`) | A missing digest for a work order created in the same transaction is an `IntegrityViolation` (new `Lockstep.Persistence.Integrity`), which aborts and rolls back the transaction | compliance `6.`: a violation inside `O.withTransaction` rolls back what was written |
| 7 | Corrupt rows read as `Organized` / `StageBasis` (`Application/Projects.hs`, `Application/Engine.hs`) | Typed columns: `Persistence.Fields.codeField` (`convertField` + `tryConvertSqlType`); `ProjectRow.rowSetup :: SetupState`, `TransactionRow.txRowStage :: Stage`; an unknown stored code fails the read | compliance `7a.` (field decoding), `7b.` (a corrupted project row, CHECK constraint dropped in the disposable database, fails to read) |
| 8 | PostgreSQL's error dropped when a migration fails (`Persistence/Migrate.hs`) | `MigrationSqlFailed` carries the message; `MigrateReport` (`runMigrationsReporting`, `migrateWithPolicyReporting`) keeps it beside the frozen `MigrateError`; `lockstep db migrate` prints it | compliance `8.`: the frozen classification `MigrateFailed two [one]` plus PostgreSQL's `does_not_exist` message |
| 9 | Unchecked narrowing of caller integers (`Application/Ledger.hs`) | `withinInteger` (base's `toIntegralSized`) at every Ledger entry that takes a caller's revision or generation: out of range is `revision-out-of-range`, nothing written. Key lifetimes above `maxBound :: Int64` refused by the Kernel's `mkEffectSpec` | compliance `9a.` (2^32+1 formerly narrowed to the real revision 1; now refused, no refusal row), `9b.` |

Checked and not defects:
- `Kernel/Decision.hs:91` hashes the request as sent (the frozen C-P3.8 M2 canonical payload). The text applied is the
  same trim the check validated (`Application/Decisions.hs` `perform`).
- `Application/Profiles.hs` version narrowing: the Kernel bounds versions to 1–1,000,000 (`mkProfileDefinition`).
- `Application/Tasks.hs`: priorities are Kernel `Priority` values (0–999); revisions are range-checked (C-C.R1 R3).
- Orville 1.1.1 has no `bytea` SqlType (ghci: `Orville.PostgreSQL.Marshall.SqlType` exports none), so
  `Fields.digestField` stays (audit "not verified" item, now verified).

### Independent review of `46c38b6` (read-only agent) and resolutions

| Finding | Resolution |
|---|---|
| H1 corruption reduced to `DatabaseError`; one bad row stalls the engine worker silently | New `NotReadyReason` case `DatabaseCorrupt Text`: `withDatabase` classifies `IntegrityViolation` and Orville's `MarshallError` (row decode) with their message; `reasonDiagnosis`; the engine worker's pass reports a list it could not read (`PassDatabase`) and logs it with the diagnosis instead of `fromRight []`; Engine stages say `database-corrupt`, not `database-unavailable`. Compliance `7c.`: a corrupt row through `findProject` is `DatabaseCorrupt` naming column and value |
| M1 siblings of defect 6 | `admitBug`: an admission not read back after its insert is an `IntegrityViolation` (was a committed refusal). `Profiles.storedDefinition`: a stored Profile that fails its digest aborts `decideChecks`/`handOver` (was "bug-checks-missing"). `Tasks.views`/`findTask`: a task whose Ticket does not replay is an `IntegrityViolation` (was dropped / "unknown"). `ProjectChecks.choiceOf` kept: the Checks page shows such a set as "damaged" explicitly |
| M2 refusal-row command fallback | Kernel `refusedTicketInputText` / `refusedWorkOrderInputText`: one total, documented rule (the event text when durable, else the input's name); the Ledger uses them |
| M3 `contentDigestFromBytes` accepted any length | It takes `SizedByteArray 32 ByteString` (memory); `Foundation.Digest.sha256Sized` is the single stated bridge from crypton's `Digest SHA256`, checked by compliance `1.` |
| M4 weak tests | `5.` pins the stored bytes `"create"`; `5b.` the refusal text; `7a.` round-trips every `Stage`; `7c.` goes through the application. Not covered end to end (setup cost of a live transaction / open Human Request): the stored conversation body and a corrupt `stage` row through `advance`; their fields are covered by `4.` and `7a.` |
| L1 hand-written SHA-256 hex remains | Recorded for Increment F (shared digest helpers) |
| L2 stage has two sources of truth | Increment C (typed `stateFromColumns`) |
| L3 `int32` unchecked | Increment C (typed revisions and generations) |
| L4 conversation digest over raw input | Disposition: deliberate. The H5 idempotency digest is over the request as sent, so a replay of the same request matches; changing it would break existing receipts' keys |
| L5 `reportCause` is a plain string | Accepted: PostgreSQL's message is free text; it goes only to the operator's terminal |

Qualification (this Mac, Docker, `scripts/check --integration` on the Increment A working tree over `469c267`):
format, lint and static checks, build, unit **870/870**, guard, integration **571/571**, backup/restore — all PASSED
(`.local/td-check-A.log`); lockstep-compliance **32/32** (`.local/td-compliance-1.log`).

After the review fixes and B1 (`scripts/check --integration`, working tree over `46c38b6`,
`.local/td-check-A2.log`): format, lint, build, unit **870/870**, guard PASSED; integration **570/571** — the one
failure, `LifecycleHelperTest` "service-stop on a running service stops it and says ok", is a pre-existing race between
the frozen helper and the frozen test (`scripts/control-helper` `execute` writes the result, line 529, before the
journal's `end` line, line 533; the test reads the journal as soon as it sees the result). The group re-run alone
passed 16/16 (`.local/td-lifecycle-rerun.log`); no change here touches either file. **Owner item:** journal `end`
before `write_result`, or the test waiting for the `end` line (both are protected files).
lockstep-compliance **34/34** (`.local/td-compliance-2.log`).

## Increment B — identity

- **B1** (`5947b7b`): Kernel identities over `Data.UUID.Types` (`uuid-types`); `parseUuid` is `UUID.fromText` plus the
  canonical round-trip rule; generation is `Data.UUID.V4.nextRandom` (no hand-set bits, no nil fallback). New
  `ProjectId`, `TaskId`, `TransactionId`, `InvocationId`, `HumanRequestId`; `parseIdentity` / `identityText` over
  `Coercible Uuid`.
- **B3/B4**: `Lockstep.Persistence.Entity` (Artificer's `Database.Entity`, adapted: `EntityKey` type family, `Table`,
  `mkEntityTable`, `keyField`/`identityField` over `O.uuidField` via `O.coerceField`, `foreignKeyTo` derived from the
  referenced table). Every keyed table is keyed by its identity type; FK columns derived from the referenced table
  except where the schema declares no constraint (decision logs, receipts' polymorphic subject, the sandbox's own
  key) — each commented. Polymorphic subject columns are typed `Uuid` with their kind column. `Fields.uuidField`
  (uuid carried as `Text`) removed. Application parses text once at each public entry (`parseIdentity`) with the
  entry's existing refusal code; `canonicalId`, `validId`-style re-parsing and `uuidOf` removed.
- **B5**: compliance `IdentityTest` (round trips per kind, non-canonical refused, version 4, a typed key through
  PostgreSQL); compile-time negative fixture `.local/td-fixtures/IdConfusion.hs` rejects a `WorkOrderId` where a
  `ProjectId` is required and a `TaskId` key on the project table (`.local/tdB-fixture.log`).
- **Frozen-pinned Text boundaries** (Application records/functions the frozen suites construct or call with `Text`;
  typed beneath, converted at the boundary; owner amendment request in the completion packet): `ProjectView.projectId`,
  `findProject`/`connectProject*`; `NewTask.newTaskProject`/`newTaskDependencies`, `TaskEdit.editDependencies`,
  `TaskView.taskId`/`taskProject`/`taskDependencies`, `createTask`/`editTask`/`decideTask`/`findTask`;
  `Admission.*`, `Enablement.enablementProject`/`enablementRepository`, `enableExecution`/`admitBug`/
  `executionStatus`/`findAdmission`; `TransactionView.viewId`/`viewWorkOrder`/`viewTask`, `InvocationView.invocationId`,
  `startTransaction`/`advance`/`transactionView`/`transactionForWorkOrder`/`decideCompletion` (typed
  `startTransactionFor`/`advanceTransaction` used internally); `StoredRequest.*`, `StoredMessage.messageRequest`,
  `NewHumanRequest.newRequestWorkOrder`, `postMessage`/`conversation`; `RepositoryRecord.repositoryRecordId`;
  `DecisionReceipt.receiptSubject`, `decidedReceipt`/`findDecision`; `ProjectChecks` entry points;
  `LedgerView.RefusalLine` subject; Kernel `createsCycle` (Text), `decisionSubject`.
- Behaviour change: `decidedReceipt` with non-canonical (upper-case) subject text is refused as `unavailable`
  (PostgreSQL used to accept it); Web already refused such input.
- Qualification (`scripts/check --integration`, working tree over `5947b7b`, `.local/td-check-B.log`): format, lint,
  build, unit **870/870**, guard, integration **571/571**, backup/restore — all PASSED; compliance **38/38**.

### Independent review of `5947b7b` + `cd2aea5` and resolutions

| Finding | Resolution |
|---|---|
| H1 JobId, ReceiptId, ProfileId missing | `JobId`/`ReceiptId` (Int64 newtypes, `Show` = the bare number, so no rendered byte changes) key `lockstep_command_receipts`/`lockstep_jobs` (`Entity.serialKeyField`; `jobs.receipt_id` derived with `foreignKeyTo`), carried through CommandCenter, Dispatcher, Command, Web/Operator, Web/CommandCenter, Main. The Kernel's `ProfileId` is a typed column (`codeField` over `mkProfileId`) through Profiles, repository profiles, Ledger sources, enablements |
| M1 pinned list inaccurate | Unpinned fields typed (`InvocationView.invocationId`, `RepositoryRecord.repositoryRecordId`, `Enablement.enablementRepository`, `StoredMessage.messageRequest`, `TransactionView.viewTask`); `projectStarted :: ProjectId`, `haltRequest :: TransactionId`; `listTasks` added to the list; `Command.Receipt.receiptId` (Int64) pinned by `CommandTest` |
| M2 render-then-parse | `Conversation.openRequestAbout` (typed `WorkOrderId`) used by the Engine; the pinned `openRequest` parses and delegates. The project page shows "could not read whether it has started work" on a failure (was `fromRight False`) |
| M3 untested behaviour change | `decidedReceipt` treats non-canonical text as no such receipt (`Right Nothing`), not `unavailable`; compliance test |
| M4 negative fixture not in qualification | compliance `NegativeTypesTest` with `should-not-typecheck` (compliance suite only): a `WorkOrderId` where a `ProjectId` is required, and a `TaskId` as the project table's key, do not typecheck; a control does |
| L1 hand-formatted UUIDs | Not changed: frozen `ClaudeAdapterTest` pins `sessionIdOf` (derived from the 32-hex workspace name) |
| L2 `foreignKeyTo` takes the key field separately | Recorded |
| L3 undocumented FK omissions | Comments added (tickets/work orders → subjects; tasks.ticket_id → tickets: key types differ) |
| L4–L7 | Recorded for Increments C (`DecisionSubject` sum), E (Web `validId`, two-kind route) and F |
| (found while fixing) `Web/Operator.parseReceiptId` wrapped a large URL number with `fromInteger` | `toIntegralSized`: out of range is no receipt |

Qualification after the fixes (`.local/td-check-B2.log`, over `cd2aea5`): format, lint, build, unit **870/870**, guard
PASSED; integration **570/571**, the one failure again the `LifecycleHelperTest` journal race (owner item above;
group re-run 16/16, `.local/td-lifecycle-rerun-2.log`); compliance **42/42**.

## Increment C — typed state and persistence boundaries

- Transaction: Kernel `StateName`, `HaltCode` (one encoder `haltCodeText`, one total decoder; parameterised codes built
  through it); `stateColumns` no longer carries the stage; typed `stateFromColumns` (also refuses accepted/done at a
  stage other than accept); `TransactionRow.txRowState :: TxState` decoded with state, stage and halt code together
  (`O.marshallPartial`), stage derived in one place; record and invocation stage columns typed.
- Task: `TaskState`/`parseTaskState`; the `otherwise -> BeingWorkedOn` catch-all removed; an unknown state is
  `StateUnrecognised` (admission `task-not-ready`; the page offers no actions).
- Intents: state and class columns typed (`IntentStateName`, `EffectClass`); typed filters; `restoreIntent` matches
  typed values.
- Invocation outcomes: Kernel `RoleEnding`, `CommandEnding`, `OutcomeKind` with one encoder/decoder; no
  `stripPrefix`/`isPrefixOf`; "executable missing" is a typed `CommandFailure` classified once (no `isInfixOf`).
- Review verdict typed (`== Approve`); attested provenance: Kernel `Provenance`/`Reason`, one writer
  (`attestedReasonText`) and one documented decoder (`reasonOf`); resolution basis typed (`ResolutionBasis`); job
  state a typed column.
- Fleece: every enum field of the engine records through `FC.boundedEnum` (mutant run through `FC.validate`).
- Web: ExecutionPages and TaskPages parse state/stage/halt once and render an unrecognised one visibly.
- Evidence: compliance `StateTest` (old string expressions as oracle: halt codes, recovery decoder, endings, every
  state/task/intent/class/basis/job name; unknown values refused) and JsonTest enum group (record bytes equal the
  hand-built literal tree for every value). Compliance **68/68**.
- Behaviour changes: impossible state/stage/code combinations or unknown stored stages/enum names fail to read
  (`database-corrupt` / `LedgerIntegrity` code `integrity`) instead of `transaction-unreadable`, silent acceptance or
  "needs a person"; executable-missing is an exact code match; an unknown task state is shown as unrecognised.
- Remaining Text (recorded): receipt outcome (`Outcome` sits above Persistence), subject kind, decision operation and
  outcome columns, profile decision outcome, resume/completion choices, the `InputRecord` input name, the invocation
  outcome column (holds both endings; typed at the Application boundary), `StoredRequest` text checks.
- Frozen-pinned (amendment list): `TxState` `Halted Stage Text` / `Stopped Text` (unit `TransactionTest.hs:111-191`,
  `CandidateTest.hs:111-120`); `TransactionView.viewState`/`viewStage`/`viewHalt` (`EngineTest.hs:227,267`…);
  `TaskFacts`/`DependencyFact` text states (unit `TaskTest.hs:41-94`), `TaskView.taskState` (`TasksTest.hs:120`);
  `IntentState` reasons carrying the marker text (unit `ReconciliationTest.hs:264-271`, `RemediationTest.hs:214-222`;
  integration `ReconciliationTest.hs:258-274`); `StoredResolution.resolutionBasis :: Text` (`LedgerPageTest.hs:150`,
  integration `ReconciliationTest.hs:260`); `RunnerFailure` constructors (`RolesTest`, `LiveAdapterTest`,
  `EngineRecoveryTwoTest`); `roleOutcomeCode` text (`RolesTest.hs:147-203`).
- Qualification (`.local/td-check-C.log`, working tree over `b187668`): format, lint, build, unit **870/870**, guard,
  integration **571/571**, backup/restore — all PASSED.

### Independent review of `ac0e158` and resolutions

| Finding | Resolution |
|---|---|
| H1 attestation forgery: a destination's reason starting with the marker read as "attested by a human" | Closed on the writer side (the prefix reader is pinned by unit `RemediationTest.hs:219`): Kernel `observed` (`Effect.hs`) stores any observation reason carrying the marker as `IntentUnknown "malformed-answer"`; the same hole in reconciliation lookups (`LookupFound` → applied) guarded (`Reconciliation.hs`). Compliance negatives for forged not-applied, applied, no-answer and lookup answers; a person's attestation is still ATTESTED |
| M1 halt-code spelling decisions; `haltCodeFromText` not injective | `HaltFixed FixedHalt` (the 15 codes Lockstep spells), `HaltRefused PlainCode` through `mkPlainCode`; decisions via the decoder; injective; ExecutionPages matches constructors; StateTest round-trips every code the state machine produces from every stage at the budget edges |
| M2 text decisions | `factAttestedApplied` computed from typed resolution rows; `RecordKind` typed column; profile source `LayerLevel` typed (`override` refused). Deferred to D: refusal-code branching (Execution, Tasks, Projects), subject-kind literals, `ProjectChecks.levelText` |
| M3 one corrupt row blocks all transactions | `activeTransactions` selects ids only. `busyTransactions` still decodes rows: a corrupt running/halted row for an Engineer fails that Engineer's next start closed (`DatabaseCorrupt`); others unaffected |
| L1–L9 | `findJob`/`findJobForReceipt` return `Either NotReadyReason` (CLI prints the diagnosis; receipt page 503); `finishJob` takes `JobEnd`; per-state halt lines; one `Kernel.Enum.parseEnumText` (Foundation's protocol parsers keep theirs: henforcer forbids Foundation → Kernel); unused `commandEndingFromText` removed; an undecodable verification/review record at acceptance halts `supervisor-failed …-record-unreadable`; PostgreSQL test of corrupt state/stage/halt combinations |

Behaviour changes: a destination or lookup answer carrying the marker is an unknown outcome; only the exact
`no-coding-agent` code gets its words; `lockstep job show` reports an unreadable database; the receipt page answers
503 when its job cannot be read; undecodable acceptance records halt with their own reason; a stored override level or
unknown record kind fails to read.

Qualification (`.local/td-check-C2.log`, over `ac0e158`): format, lint, build, unit **870/870**, guard PASSED;
integration **570/571** — the failure is `ReconciliationTest` "two processes recover one crashed idempotent intent"
(`refused lease-active`), the pre-existing race already recorded in the P4.L.R3 packet (two recoverers racing; the
frozen P2.7 test does not list that legitimate code); re-run alone 2/2 (`.local/td-recover-rerun.log`). Owner item
together with the lifecycle journal race. Compliance **77/77**.

Behavioural differences (deliberate): an expected revision above `Int64` is refused (was wrapped); a Ledger revision
or generation above `Int32` is refused before anything is written (was wrapped into a refusal or observation row); a
corrupt setup or stage column is a read failure (was shown as organized / basis); `lockstep db migrate` prints
PostgreSQL's message after the existing sentence.

## Increment D — typed failures (working tree over `1bf37a2`, not committed)

- **Ledger refusals** (`Application/LedgerRefusal.hs`, new): `LedgerRefusal`, one constructor per Ledger decision
  (multi-message codes carry a rule: `RecordRule`, `StaleSubject`, `FactsRule`, `EvidenceRule`, `OwnershipLoss`,
  `InactiveFor`, `KeyExpiry`) or the Kernel's typed refusal (`TransitionRefused`, `EffectRefused`, `SchedulerRefused`,
  `ProfileRuleRefused`, `RecoveryRefused`, `ReconcileRefused`, `CarryRefused`); one `ledgerRefusalCode` and one
  `ledgerRefusalMessage`. Inside a transaction the Ledger works in `LedgerError = LedgerRefusedBy LedgerRefusal |
  LedgerCorrupt Text`; `transaction` renders it once (`publicFailure`). The executor, reconciler, sandbox, decisions and
  CLI build their refusals through it too. No code literal is left in the Ledger.
- **Frozen pin kept**: `LedgerFailure = LedgerRefused Text Text | LedgerIntegrity Text | LedgerUnavailable Text`
  (integration `LedgerTraceTest.hs:247-252` matches the three constructors exhaustively; `ledgerFailureCode` text in
  `LedgerTest.hs:335,357`, `ReconciliationTest.hs:693,720,732`, `RemediationTest.hs:250,255`, `ExecutorTest.hs:568` and
  others). It is now only the rendering; the unpinned `*In` functions (`createTicketIn`, `reviseTicketIn`,
  `ticketFactsIn`, `decideTicketIn`, `createWorkOrderIn`) return the typed `LedgerError`.
- **Branching on the typed refusal**: `Execution.admitBug` (`TicketNotReady`, `RepositoryDefaultProfileUnset`),
  `Tasks.decideTask` (`StaleRevision _`), `Ledger.observeIntent` (`EffectRefused StaleClaim`), `Projects`
  (`Repositories.RepositoryRefusal`: `EngineerNameTaken`, `RegistrationRefused (AuthoritativeRemoteAmbiguous _ /
  AuthoritativeRemoteUnknown _)`). `Web/App` compares the frozen `Either Text` checks code (`GateCRemediationTest.hs:438`)
  through `ProjectChecks.checksRefusalCode FewerChecksUnconfirmed`.
- **Kernel refusal words**: `transitionRefusalMessage`, `effectRefusalMessage`, `schedulerRefusalMessage`,
  `recoveryRefusalMessage`, `reconcileRefusalMessage`, `carryRefusalMessage` replace `T.pack (show r)` (no frozen test
  pins those messages; only codes are pinned, e.g. `ProfileRegistryTest.hs:310`). Integrity texts no longer embed `show`.
- **Stringly exceptions**: `Persistence.Ledger.databaseClock`/`databaseNow`, `Profiles.record`, `Repositories.record` and
  its malformed-row check, `Command` receipt insert → `integrityViolation` (so `withDatabase` gives `DatabaseCorrupt`
  with the message). The sandbox adapter throws a typed `SandboxFailure` (still `adapter-failed` to the executor).
- **Swallowed results**: an advance of a halted transaction whose request cannot be opened answers with its code (was
  "idle halted"); a command finish that cannot be written is the failure (was dropped before halting / returning); the
  worker reports each start that failed (`start <id>`; database failures are logged with the diagnosis) instead of
  `[] <$ traverse_`; the workspace symlink check fails closed on an error other than "does not exist" (was
  `fromRight False`); the control pane logs a fixed line as `lockstep serve` does (was `\_ _ -> pure ()`); a halt for an
  intent whose reason cannot be stored is an integrity violation, a halt the lifecycle refuses is kept, commented. Kept,
  commented: the request opened after a committed step (the next advance reopens it and reports).
- **Text-keyed word tables**: every remaining one takes text from a stored row or a frozen `Either Text` boundary and
  is pinned with its general sentence (`ActivityTest.hs:95-97`, `DecisionTest.hs:113-116`, `PolicyTest.hs:220-223`);
  each now says so. No caller holding the ADT uses a text table.
- **`show` in stored/hashed forms**: Kernel `principalLabel` (the constructor spelling) for conversation message rows,
  the H5 canonical message text and (lower-cased) transaction records; Profile refusal words; `Profile.showText` is
  `Int`-only.
- **Deferred C items**: `Persistence.Ledger.SubjectKind` (typed `kind` column via `codeField`; the intent join reads it
  typed); `ProjectChecks.levelText` removed for the Kernel's `layerName`.
- **Kernel `Either Text` refusals** (Transaction, Conversation, Roles, Runner, GitBasis, Decision): no caller branches
  on them except the runner's `executable-missing`, classified once in Increment C; left as text (they cross frozen
  `Either Text` boundaries).
- Evidence: compliance `FailureTest` (old expressions as oracle: every Ledger refusal's code and words, the effect-key
  and sandbox words, Kernel codes unchanged, `principalLabel == show` for every principal and in the H5 text, Profile
  refusal words, subject-kind codes and a corrupt kind through the Ledger, `layerName`, checks and repository codes).
- Behaviour changes: Kernel refusal messages are words, not `show` text; a corrupt stored ticket/profile reached
  through a task, an admission or a Ledger `*In` step aborts as `database-corrupt` (was the code `integrity` or
  `admission-refused`); a missing `now()`/`clock_timestamp()` row or receipt/decision row is `database-corrupt` (was
  `database-unavailable`); a corrupt subject kind is `LedgerIntegrity` (was `unknown-ticket`/`unknown-work-order`);
  `sandboxApplications` reports the readiness code (was `show` of the reason).

### Independent review of `85fc72a` and resolutions

| Finding | Resolution |
|---|---|
| M1 every halt refusal ignored | `haltForIntentBy` ignores only `IllegalTransition`/`AlreadyTerminal` (no halt from that state); any other refusal is an integrity violation with its words |
| M2 corruption as unavailability / nothing to do | `Decisions`: `DatabaseCorrupt` → `LedgerIntegrity` (receipt read, decision lock); `receiptOf`/`currentBasis` return the failure (a Ledger refusal still means "no basis"). `executeOnce`/`reconcileOnce` (signatures unchanged) return an intent that fails to load as the pass's failure, never `Right Nothing`. `runnableIntents` propagates an order that does not replay |
| M3 `GitSupervisor.safeParents` failed open | Shared `Foundation.Filesystem.linkedOrUnreadable` (fail closed except "does not exist"), used there and by `Engine.writeExtra` |
| L1 | The settle integrity texts carry the refusal's code and words |
| L2 finish failure masked the run's failure | `CommandFailure.FinishNotRecorded db original`; its code is `<db>-after-<run>`; `finishAndHalt` answers with the same |
| L3 | `ProjectChecks.chooseChecksTyped` (typed `ChecksRefusal`) under the frozen `chooseChecksExpecting`; `Web/App` matches `FewerChecksUnconfirmed`. `Decisions.ReceiptOutcome`/`receiptOutcomeCode`/`receiptApplied` (receipt rows written through it); `Web/App` uses `receiptApplied` (`DecisionReceipt.receiptOutcome` stays `Text`) |
| L4 | `sandboxApplications`: `DatabaseCorrupt` → `LedgerIntegrity` |
| L5 | `FailureTest` decodes through the production `subjectKindField`, checks each rule enum's oracle covers `[minBound .. maxBound]`, pins receipt outcome codes |

Remaining (recorded, not changed in D): `Database.classifyConnectionFailure` (`Database.hs` ~113-124) classifies libpq's
message text; `Effects/Git.hs` ~218 matches git's messages — both predate this work and depend on external tools'
wording. `Conversation.postMessage` still answers `integrity` as a code when a stored request does not rebuild; the
text state literal `active` in `runnableIntentIds`; integer `show` in canonical texts (a fixed decimal format); no
end-to-end test of a corrupt intent through `executeOnce` (the setup of an order with intents in the compliance suite).

## Increment E — typed web architecture (`b6263f4`; review fixes in the working tree)

- **E1 routing**: one Beeline route tree per area, each a Shrubbery `Union` of route types with every path defined
  once as a builder polymorphic in the router and used both to recognise requests (`R.RouteRecognizer`) and to
  generate the links (`B.get` / `B.post`): `Web/Routes/App.hs` (pages → shell, fragments, actions; subrouters),
  `Web/Routes/Operator.hs`, `Web/Routes/Control.hs` (each API path also yields its OPTIONS preflight). Typed path
  parameters in `Web/Routes/Params.hs` (`R.convertParam` over the Kernel's `parseIdentity`; `ReceiptId`; the pane's
  `RequestId`; sections and the pane's two assets as `boundedEnumParam`). Dispatch is `Shrubbery.dissect` over the
  union in `Web/App.hs`, `Web/Operator.hs`, `Web/Control.hs`; the three `case pathInfo` routers and `validId` are gone.
  The two-kind decision address (`/app/decisions/<uuid>`, pinned) is a `DecisionKey` built only from a `WorkOrderId`
  (`stoppedWorkKey`) or an `OperationId` (`unknownOutcomeKey`); the request's kind comes from the typed
  `DecisionChoice` checked against the open decision (`choiceFits`), never from a string.
- **E3 validation**: `Web/Validation.hs` (Artificer/Launchpad applicative `Validator`, errors accumulated per field)
  over `Orb.Form` read by `Web/Form.hs` (strict UTF-8, values in order; `Orb.getForm` is not used: it decodes with a
  partial decoder and throws on invalid UTF-8); field names declared once in `Web/Fields.hs` and used by the pages'
  `A.name` and the validators. Every `/app` and `/operator` form reads through validators (typed `IdempotencyKey`,
  `FolderChoice`, `Priority`, `ExpectedChecks`, `TaskAction`, `DecisionChoice`, ranged decimals, the sign-in token).
- **E4 rendering**: every internal link and form action is a typed URL from the routes (no `/app` or `/operator`
  literal left in pages); ids, names and `for` through `B.Id` / `B.Name` (`Fragment.elementId`) where the id is made of
  fixed words or a canonical identity (ids made from stored text stay the escaping `attr`); `value` stays escaped
  (`attr`, `Operator.escapedValue`: Brigid 0.4 writes attribute values unescaped). The session cookie through
  `Web.Cookie.renderSetCookieBS`. `ProjectView.projectKey`, `TaskView.taskKey`/`taskProjectKey`,
  `TransactionView.viewKey` carry the typed identities beside the pinned text fields, so no page parses view text back.
- **E2 / E5 not done**: form routes conflict with frozen pins (a form error answers 200 with the page:
  `GateCRemediationPageTest.hs:152-153,168,174-176,221`, `TasksPageTest.hs:198`, `ProjectsPageTest.hs:222`; Orb's
  `FormDataRequestBody` answers 422; `Orb.getForm` throws on invalid UTF-8 where `OperatorTrustTest.hs:232-233` pins
  4xx; the 413 limits and their order, `AppShellTest.hs:222-225`, `OperatorTrustTest.hs:236`). Body-less routes and
  `app.js`: see the review table below.
- Behaviour changes (all on malformed input): an `/app` form that is not UTF-8 or repeats a single-valued field is
  "could not read this form" (was decoded leniently / first value taken); an operator receipt address that is not a
  receipt number is unrouted (404 before the guard and the session, with the unrouted JSON 404 body and
  `application/json` content type, no longer the HTML "no such receipt" page; was 401 without a session); an OPTIONS on
  `/api/handover/<x>` or `/api/requests/<x>` with a malformed id is 404 (was 405); the `Set-Cookie` attribute order is
  the cookie library's (`Path=/; Max-Age=…; HttpOnly; SameSite=Strict`).
- Evidence: compliance `WebTest` (each generated link at its frozen address and recognised with its guard class; the
  decision key for both kinds; non-canonical ids, wrong methods and bad receipt numbers unrouted; strict UTF-8; errors
  accumulated per field name).

### Independent review of `b6263f4` and resolutions

| Finding | Resolution |
|---|---|
| M1 a non-UTF-8 operator form answered 403 (CSRF) | `Operator.withForm` hands `Maybe Form`; `withCsrfForm` answers 400 `invalidCommandPage` after the session and before the CSRF check; the sign-in exchange answers 400 `badLinkPage` (as before). A repeated `csrf` is still 403, as it was before E |
| M2 body-less routes not on Orb | Deferred to the v3 restructuring (below). Not an Orb limitation for headers or HEAD: checked in ghci (`.local/ghci/tdE-6.ghci`), `Orb.return200WithHeaders` carries any header list after Orb's own `Content-Type` (which `addResponseBody200` takes as given, e.g. `text/html; charset=utf-8`), and `Orb.dispatch` does not look at the request method (a HEAD dispatched to a GET handler answered 200), so HEAD-as-GET stays in our recognition |
| M3 `app.js` route table | Deferred to v3 (below) |
| L4 lenient UTF-8 in the control pane | `Control.utf8` (`decodeUtf8'`): a requests, lifecycle, install or folder body that is not UTF-8 is 400 `unknown-operation`; a session body that is not UTF-8 is 403 `sign-in-refused` (it cannot be a token; no frozen test sends either) |
| L5 three decimal parsers | One `Validation.digitsUpTo` (`Data.Text.Read.decimal`, ASCII digits only, at most 19 characters, at most a limit) and `Validation.decimalUpTo`; used by the app forms, the operator forms (limit 999 999 999 999 999 999) and `receiptIdParam` (same limit, then `toIntegralSized`). Behaviour change: an operator number or receipt address of exactly 19 characters with leading zeros (value within the limit) is now read (was refused for length) |
| L6 two attribute escapers | `Operator.escapedValue` is `Fragment.attr "value"`. Brigid 0.4, checked in ghci (`.local/ghci/tdE-7.ghci`): `customAttribute` escapes only `"` and `'` (`&#34;`, `&#39;`), typed `A.value` escapes nothing, text escapes `&`, `<`, `>`. Operator pages now also escape `<`, `>` in values (as `&lt;`, `&gt;`) and write `"` as `&quot;` |
| L7 dependency id from view text | `TaskPages` builds it from `identityText (taskKey t)` |
| L8 unreadable new-project form | Falls back to `emptyForm` (default folder `new` checked) with the key that was sent |
| L9 receipt 404 body | Recorded above (behaviour changes) |

**Deferred to the v3 restructuring (recorded obstacles):**

- **M2 (Orb handlers for the body-less routes).** The obstacle is the module layout, not the Orb API. An
  `Orb.HasHandler`/`Orb.PermissionAction` instance must sit with its route type (an orphan instance fails `-Werror`
  under `-Weverything`), the route types sit in `Web/Routes/*` because every page imports their links, and the handler
  code (`projectPage`, `taskAnswer`, `decisionAnswer`, …) sits in `Web/App.hs`, which imports the pages: putting the
  instances there needs Artificer's one-module-per-route layout (path builders shared, route type + handler together).
  Two further points for that step: `Orb.Has500Response` fixes the `"500"` entry to `Orb.InternalServerError`, so the
  ledger's deliberate HTML failure page (`Operator.ledgerView`, 500) cannot be a declared response distinct from Orb's
  exception answer; and the control pane runs as its own WAI application over `PaneRuntime` in `IO`, with no monad
  having `Orb.HasRequest`/`HasRespond`/`HasLogger`. Orb's exception handler also answers 500 without the security
  headers `respondWith` adds.
- **M3 (typed `hx-get`/`hx-post`/`hx-push-url` from the routes, shrinking `app.js`).** Not blocked outright by a pin,
  but every swap and history step is pinned by the browser drivers and HTTP tests, so replacing `app.js`'s
  form/link interception changes behaviour under: the shell identical and content-free for every address
  (`AppShellTest.hs:99-117`), so the deep-link bootstrap (`routeFor`, address → fragment) has to stay client-side; the
  address after a swap comes from `X-Lockstep-Path` (`ExecutionPageTest.hs:236,277`, `ProjectChecksPageTest.hs:212`,
  `DecisionsPageTest.hs:184`, `EnginePageTest.hs:396,438`) and is checked in the browser
  (`ProjectsBrowserTest.hs:115`, `ProjectChecksBrowserTest.hs:127`, `ExecutionBrowserTest.hs:143`,
  `DecisionsBrowserTest.hs:107`, `ActivityBrowserTest.hs:100`, `TasksBrowserTest.hs:144`, `EndToEndTest.hs:296`); and
  repeated `depends_on` values are sent as a list by `app.js`'s submit handler. Left for v3 with the drivers
  re-qualified, as the owner prioritises a working harness.
