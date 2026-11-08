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

Behavioural differences (deliberate): an expected revision above `Int64` is refused (was wrapped); a Ledger revision
or generation above `Int32` is refused before anything is written (was wrapped into a refusal or observation row); a
corrupt setup or stage column is a read failure (was shown as organized / basis); `lockstep db migrate` prints
PostgreSQL's message after the existing sentence.
