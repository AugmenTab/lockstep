# Raw `Text` fields — inventory and classification

Branch `remediation/type-discipline`, working tree over `b6263f4` (Increment E), read 2026-11-09. Read-only survey: no
source or test file was changed. `src/Lockstep/Web/*` was being edited concurrently; its rows are a snapshot (Web/App.hs
lines are one higher than in the first grep).

## 0. Method and scope

- **Record fields**: every line `{ name :: …Text…` / `, name :: …Text…` under `src/` (grep
  `^ +[{,] +[a-z][A-Za-z0-9_']* +:: .*Text`). This covers `Text`, `Maybe Text`, `[Text]`, `Maybe [Text]`, `[[Text]]`,
  tuples, `Map Text _` and `Either Text _`. The first grep (`bvozb81un.txt`, 483 lines) matched only `Text` and
  `Maybe Text`; this one finds **569** lines. 8 are not data and are excluded: function or mutable-cell fields
  (`Effects/Roles.hs:116 runnerPrepare`, `:117 runnerRun`, `:312 adapterPrepare`, `Effects/Executor.hs:32 adapterRun`,
  `Effects/Reconciler.hs:31 reconcilerLookup`, `Application/Projects.hs:200 faultAfterCommit`,
  `Application/ControlPane.hs:86 paneIssued` (IORef), `:88 paneLifecycle` (MVar)). **561 record fields** are classified.
- **Positional constructor fields**: constructors with a `Text` slot (grep `^ *(=|\|) +Con … T.Text`, plus constructors
  written on their own line after a haddock line). **161 constructors** are classified (one row per constructor). The
  20 newtypes that *are* typed wrappers over `Text` (`CommitId`, `ContentDigest`, `ProfileId`, `GateId`, `ClassTag`,
  `PlainCode`, `EffectKey`, `ResourceName`, `TaskTitle`, `Choice`, `ProjectName`, `ProjectOutcome`, `HumanSignoff`,
  `PullRequestRef`, `PlanRef`, `RequestId`, `Secret`, `Checksum`, `WorkspaceName`, `IdempotencyKey`) are not counted. A constructor whose `Text` argument sits on a continuation line could be
  missed by the grep; none was found by the second pattern.
- **Frozen pins (E)** were verified by grep in `test/unit`, `test/integration` and `test/stress` (not
  `test/compliance`): a frozen test constructs the record or constructor with a `Text` value, pattern-matches it, or
  compares the field with `@?=` against `Text` (including passing it where the test's own helper takes `Text`). A
  record compared only as a whole (`again @?= r`) does **not** pin its field types and is not counted as a pin.
- **Layering constraint** (henforcer.toml lines 14–20): the Kernel and Foundation may not import each other; Persistence
  may not import Application. A type used by a Persistence row must live in the Kernel (or Foundation), so
  `IdempotencyKey`, `Actor`, `Outcome` (Application/Command), `ReceiptOutcome` (Application/Decisions) and Web's
  `DecisionChoice` must move down before rows can use them.
- **Libraries in package.yaml**: `uuid`/`uuid-types` (already used), `time` (`UTCTime`), `crypton`/`memory`
  (`Digest SHA256`), `non-empty-text` (`NonEmptyText`, used in Web only), `json-fleece-*` (`FC.boundedEnum`,
  `FC.validate`), `orville-postgresql` (`codeField` pattern, `marshallPartial`). **Not** present: `bounded-text`, any
  git library, `filepath`/`os-string` as a direct dependency (only transitively through `directory`).

Categories: **A** existing type; **B** new newtype/sum needed; **C** free text (bound noted); **D** canonical/serialized,
keep; **E** frozen-pinned. `X/E` = category X and pinned.

## 1. Summary counts

### 1.1 Record fields (561)

| Layer | A | A/E | B | B/E | C | C/E | D | D/E | Total | of which pinned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Kernel | 0 | 19 | 2 | 24 | 2 | 13 | 0 | 4 | 64 | 60 |
| Foundation | 1 | 5 | 3 | 12 | 0 | 9 | 2 | 2 | 34 | 28 |
| Persistence | 74 | 0 | 44 | 0 | 14 | 1 | 22 | 1 | 156 | 2 |
| Application | 60 | 64 | 43 | 28 | 24 | 12 | 6 | 8 | 245 | 112 |
| Effects | 2 | 1 | 16 | 7 | 5 | 1 | 2 | 0 | 34 | 9 |
| Web | 14 | 0 | 10 | 0 | 3 | 0 | 1 | 0 | 28 | 0 |
| **Total** | **151** | **89** | **118** | **71** | **48** | **36** | **33** | **15** | **561** | **211** |

By base category: A 240 (151 free to change), B 189 (118 free), C 84 (48 free), D 48 (33 free). **350 fields are
not pinned** and can be typed now; 211 are pinned.

### 1.2 Positional constructor fields (161 constructors)

| Layer | A | A/E | B | B/E | C | C/E | D | D/E | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Kernel | 1 | 13 | 6 | 29 | 4 | 46 | 3 | 0 | 102 |
| Foundation | 1 | 0 | 1 | 0 | 0 | 3 | 1 | 2 | 8 |
| Persistence | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| Application | 0 | 2 | 5 | 5 | 6 | 9 | 2 | 0 | 29 |
| Effects | 0 | 0 | 8 | 5 | 0 | 6 | 0 | 0 | 19 |
| Web | 0 | 0 | 1 | 0 | 1 | 0 | 0 | 0 | 2 |
| **Total** | **2** | **15** | **21** | **39** | **12** | **64** | **6** | **2** | **161** |

Most positional `Text` is refusal/reason text inside Kernel sums, and 120 of 161 are pinned by the Kernel unit tests.

### 1.3 Headline findings

1. **Persistence is almost untyped below the identities**: of 156 row fields, 74 have an existing type (digests,
   identities' companions, `ProjectName`, `TaskTitle`, `Principal`, `WorkOrderKind`, `EffectKey`, …) and 44 need a
   new one; only `codeField` columns from Increment C are typed. **No frozen test touches a Persistence row**
   (only `Migration` is pinned), so all of this is free to change.
2. **Typed decoders thrown away**: `Persistence/Commands.hs:117` reads `payload_digest` through `digestField`
   (bytes) and stores `hexDigest` text in `rowDigestHex`; `Persistence/CommandCenter.hs:121` does the same for
   `evidenceDigestHex`; `Application/CommandCenter.hs:146` renders `Maybe JobState` back to text
   (`activityJobState`); `Application/Engine.hs:273-274` renders `TxState`/`Stage` to `viewState`/`viewStage`
   (pinned); `Projects.hs:123`/`Tasks.hs:154` render identities (pinned); `Ledger.hs:1851` renders
   `ResolutionBasis` (pinned); `Persistence/Profiles.hs:105` has a typed `profile_id` decoder but
   `profileDecisionProfile` deliberately stays text (documented at `Profiles.hs:62-65`).
3. **Duplicated invariants**: 40-hex commit check in both `Kernel/Evidence.hs:23 mkCommitId` and
   `Kernel/GitBasis.hs:118 isCommitId`; 64-hex in `Kernel/Profile.hs:154 mkContentDigest` and
   `Application/Conversation.hs:214`; 32-hex in `Foundation/ControlProtocol.hs:78 parseRequestId` and
   `Foundation/RunnerProtocol.hs:82 isRunName`; `^[a-z][a-z0-9-]{0,N}$` names in `Kernel/Profile.hs:175`,
   `Kernel/Effect.hs:104`, `Kernel/Roles.hs:201`, `Kernel/Conversation.hs:48`, and the engineer CHECK
   (`Migrations.hs:104`). Two digest types coexist: Kernel `ContentDigest` (64-hex text, has a parser) and
   Foundation `Sha256` (bytes, no hex parser).
4. **Engineer names, folders, git paths, branch names, commit/tree/blob ids, argv vectors and closed code
   vocabularies** account for most B fields; each appears in 5–25 fields across all layers.
5. The **frozen suites pin 211 record fields and 120 constructors** as `Text`. The established pattern (Increments
   B/E: `projectKey`, `taskKey`, `viewKey`) — a typed field beside the pinned text view — applies; a full fix needs
   the owner's amendment of the frozen tests listed in §4.

## 2. New types proposed (B)

Place every type that a Persistence row needs in the **Kernel** (Persistence imports Kernel; Kernel imports neither
Foundation nor Application). Foundation protocol types must be Foundation's own (the Kernel cannot be imported there).

| # | Type (proposed module) | Invariant | Library? | Fields that would use it |
|---|---|---|---|---|
| B1 | `EngineerName` (Kernel/Repository or new Kernel/Engineer) | `^[a-z][a-z0-9-]{0,39}$` (CHECK `Migrations.hs:104`) | no | Persistence: Transactions 98, 585; Execution 50; Conversation 41; Projects 44; Repositories 56, 69, 84; Profiles 72. Application: EngineRecords 108; Engine 202; Conversation 102, 115, 219; Projects 112; Execution 120; Repositories 108, 114, 121; Ledger 552; Profiles 100 |
| B2 | `AbsolutePath` (Kernel; Foundation needs its own `FolderPath`) | starts with `/`, no NUL, no `..` segment (Runner R1, `Kernel/Runner.hs`), no `:` (folder-list separator, `FolderProtocolTest.hs:113`) | `System.OsPath` (filepath ≥1.4.100) would need `filepath` added and is host-encoded; the values are stored and compared as text, so a Kernel newtype over `Text`, converted to `FilePath` in Effects, is the better fit | Kernel: Repository 100; Runner 48; `ExistingFolder`, `LocalIdentity`. Foundation: FolderProtocol 61. Persistence: Transactions 99, 586; Execution 51; Projects 43; Repositories 57. Application: EngineRecords 109; Engine 203; Projects 111; Execution 121; Repositories 116; ControlPane 341. Effects: Roles 91–93. Web: App 451; Json 145 |
| B3 | `TreePath` and `ProtectedPath` (Kernel/GitBasis) | `treePathValid` (G1, `GitBasis.hs:72`): relative, 1–4096, no empty/`.`/`..`/`.git` segment, no control or `\`; `ProtectedPath` adds `protectedPathValid` (`GitBasis.hs:91`) | none (git paths are `/`-separated UTF-8, not host paths) | Kernel: GitBasis 52, 63; Roles 60, 81, 99 (Protected), 120, 128. Application: EngineRecords 252 (P), 315, 328 (P), 363, 379. Effects: Roles 543, 608 (P), 633, `DocCitation`, `DocFile`, `DocSupplement`; GitSupervisor 479 |
| B4 | `TreeId`, `BlobId` beside `CommitId` (Kernel/Evidence; or one `GitObjectId kind`) | 40 lower-hex (same as `mkCommitId`); retire `GitBasis.isCommitId` | no git library in package.yaml | Kernel: GitBasis 54. Application: EngineRecords 208. Effects: GitSupervisor 173 |
| B5 | `WorkBranch` (Kernel/GitBasis) | always `lockstep/<work order uuid>` (`GitBasis.hs:123 workBranch`): build it from `WorkOrderId`, render once | no | Persistence: Transactions 111. Application: EngineRecords 209, 295, 451; Engine 208 |
| B6 | `GitRemoteName` (Kernel/Repository) | a git remote name: non-empty, no `/`, whitespace or control (git `check-ref-format` component rules) | no | Kernel: Repository 82, 90, 103; `AuthoritativeRemoteAmbiguous/Unknown/Inconsistent`. Persistence: Repositories 59. Application: Repositories 115 (fst), 123; `Observed` |
| B7 | `RunName` (Foundation) — or one `Hex128` shared with `RequestId` | 32 lower-hex (`isRunName`, `RunnerProtocol.hs:82`) | `Data.UUID` does not fit (not the canonical UUID spelling; the frozen `sessionIdOf` derives a UUID *from* it) | Foundation: RunnerProtocol 75. Effects: Roles 104; HelperRunner 78 |
| B8 | `LeaseOwner` (Kernel/Effect) | non-empty, no control character (no validator exists today; values are executor names, `"w1"`) | no | Kernel: Effect 178; Recovery 39; `IntentClaim`. Persistence: Ledger 527. Application: Executor 41 |
| B9 | `RoleArgv` (Kernel/Roles) and `RunArgv` (Kernel/Runner) | `argvValid` (`Roles.hs:214`): 1–64 words, each ≤4096, no NUL, first non-empty; `RunArgv` R1 (`Runner.hs:80`): 1–1024 words, each ≤32768, total ≤262144, no NUL | `NonEmpty` from base for the list | Kernel: Roles 69, 102, 121; Runner 47. Application: EngineRecords 226, 316, 330, 398; EngineEvidence 44, 84. Effects: Roles 611, 634, `DocCheck`, `DocSupplement` |
| B10 | `FailureSignature` (Kernel/Roles) | 1–200 printable ASCII (`signatureValid`, `Roles.hs:210`) | no | Kernel: Roles 70, 103. Application: EngineRecords 227. Effects: Roles 612, `DocCheck`, `DocSupplement` |
| B11 | `CriterionId` (Kernel/Roles) | `^[a-z][a-z0-9-]{0,39}$` (`criterionIdValid`, `Roles.hs:201`) | no | Kernel: Roles 109, 142. Application: EngineRecords 274, 322; EngineEvidence 63. Effects: Roles 587, 720 |
| B12 | `EnvName` (Kernel/Runner) | `^[A-Za-z_][A-Za-z0-9_]{0,127}$` (`Runner.hs:111`); value ≤32768, no NUL | no | Kernel: Runner 49 |
| B13 | `CheckName` (Kernel/WorkUnitLifecycle) | the frozen contract's required check names (non-empty, unique; `mkFrozenContract`) | no | Kernel: WorkUnitLifecycle 98; `FrozenContract`, `Verified`, `WuGatePassed/Failed` |
| B14 | `Approver` (Kernel/Profile) | the binding approver; today only `"operator"` (`Ledger.hs:563`, C-P1.3) and a person's name in overrides/receipts | no | Kernel: Profile 995; `Override`, `NonBehaviouralBasis`, `ExceptionReceipt`, `ProfileConfirmation`. Persistence: Ledger 376 |
| B15 | `HumanEvidence` / `SenderEvidence` (Kernel/Conversation) | the closed sum `senderEvidence` renders (`Application/Conversation.hs:82`): `application-session` \| `cli-session` \| `planner-invocation <InvocationId>` \| `supervisor` \| `agent <label>` | no | Persistence: Conversation 64; Execution 55, 67; DecisionReceipts 35. Application: Conversation 134; EngineRecords 169; Execution 125, 145 |
| B16 | `MessageChannel` (Kernel/Conversation) | `application` \| `cli` \| `engine` (CHECK `Migrations.hs:564`); Application `Channel` lacks `engine` | no | Persistence: Conversation 65. Application: Conversation 135; EngineRecords 168 |
| B17 | `RequestStateName` (Kernel/Conversation) | `open` \| `answered` \| `withdrawn` (CHECK `:548`); decode with the answer column into `RequestState` via `marshallPartial` | no | Persistence: Conversation 49. Application: Conversation 123 |
| B18 | `DecisionChoiceName` (Kernel/Decision; move Web `DecisionPages.hs:43 DecisionChoice` down) | `put-back` \| `cancel` \| `happened` \| `did-not-happen` \| `try-again` \| `give-up` (CHECK `:463`) | no | Persistence: DecisionReceipts 31. Application: Decisions 101 |
| B19 | `DecisionSubject` (Kernel/Decision) | `StoppedWork WorkOrderId \| UnknownOutcome OperationId` (the two-kind subject; Web already has `DecisionKey`) | no | Application: Decisions 100 |
| B20 | `HaltChoice`, `CompletionChoice` (Kernel/Transaction) | `retry` \| `stop` \| `accept-non-reproduction` (`haltChoices`, `Transaction.hs:115`); `done` \| `not-done` | no | Application: EngineRecords 152, 167. Web: App 685 |
| B21 | `TxInputName` (Kernel/Transaction) | one name per `TxInput` constructor (`txInputName`) plus the idle reasons | no | Application: EngineRecords 137; `Stepped`, `Idle` |
| B22 | `StageRefusalCode` (Kernel/Transaction) | the closed set of codes `BasisRefused`/`CandidateRejected`/`ImplementationRefused`/`ScopeRefused`/`VerificationInconclusive`/`RoleFailed`/`RoleUncertain`/`SupervisorFailed` carry (Git refusals, candidate rejections, scope codes) — `PlainCode` stays the escape for codes not yet enumerated | no | Application: EngineRecords 195, 362. Kernel: those 8 `TxInput` constructors; `HaltRoleFailed/HaltUncertainInvocation/HaltSupervisorFailed`; Runner `RoleEndedFailed/RoleEndedUncertain`; Effects `RoleFailed/RoleUncertain` |
| B23 | `RunnerName` (Kernel/Runner) | `direct` \| `container` (CHECK `:622`) | no | Persistence: Transactions 140. Application: Engine 189. Effects: Roles 115 |
| B24 | `AdapterName` (Kernel/Runner) | the adapters Lockstep has (`supervisor`, scripted, `claude-code`, …): a closed sum | no | Persistence: Transactions 141. Application: Engine 190. Effects: Roles 311 |
| B25 | `InvocationSubject` (Kernel/Runner) | `^[a-z][a-z0-9-]{0,63}$` (CHECK `:621`): a `Role` or a Supervisor check (`reproduction`, …) | no | Persistence: Transactions 139. Application: Engine 188 |
| B26 | `AnswerKind` (Kernel/Roles) | `discovery` \| `candidate` \| `challenge` \| `implementation` \| `review` (one per `RoleAnswer` constructor) | `FC.boundedEnum` | Effects: Roles 483, 538, 631, 747; `DocImplementation`, `DocReview` |
| B27 | `CommandKind` (Kernel; from `Application/Command.hs:221 commandKind`) | `rename-workspace` \| `queue-noop` | no | Persistence: Commands 40, 55; CommandCenter 46. Application: CommandCenter 57; Command 299 |
| B28 | `IdentityOperation`, `ProfileOperation`, `ProfileDecisionOutcome` (Kernel) | CHECK `:126` (`engineer-add` \| `repository-register`), `:164` (`profile-add` \| `repository-set-profile`), `:170` (`accepted` \| `unchanged` \| `refused`) | no | Persistence: Repositories 68; Profiles 68, 74 |
| B29 | Refusal-code enums per decision log (Kernel): `RegistrationRefusalCode` (code of `RegistrationRefusal`), `ProfileRefusalCode` (Application `ProfileFailure` codes), `ProjectSetupRefusal`, `TransitionRefusalCode`, `ObservationRefusal`, `ChecksRefusal` code | each a closed `Enum, Bounded` with the code function that already exists; the payload-carrying ADTs keep their payloads | no | Persistence: Repositories 72; Profiles 75; Projects 42; Ledger 284, 743; DecisionReceipts 34. Application: Projects 110; Decisions 104; Ledger 1454; LedgerView 90; ProjectChecks 113, 139; LedgerRefusal constructors |
| B30 | `WorkOrderStateName` (+ `TaskState` for tickets) (Kernel/WorkOrder) | one name per `WorkOrderState` constructor (`workOrderStateName`); the subject row's state decoded with its kind (`marshallPartial`) | no | Persistence: Ledger 142, 229. Application: Ledger 242, 250 |
| B31 | `EffectSpecName` (Kernel/Effect) | `validName` `^[a-z][a-z0-9-]{0,63}$` (CHECK `:258`) | no | Persistence: Ledger 512. Application: Decisions 78; `EffectSpec`; `UnknownSandboxEffect` |
| B32 | Small closed sums: `SandboxOutcome` (`applied` \| `fenced`, CHECK `:397`), `FolderMode` (`rw` \| `ro`), `ClaudeModel` and `Effort` (`supportedModels`/`supportedEfforts`, `Claude.hs:55-62`), `RunnerOutcomeCode` (exited, timed-out, cancelled, launch-failed, refused, interrupted, output-limit, provider-stopped), `ProviderStopCode`, `HelperReasonCode`, `OpName` (union of the helper protocols' ops), `EvidenceKind`, `SummaryStatus`, Web `ResultState`/`StateBody` values, `FieldName` (Web/Fields) | as listed | `FC.boundedEnum` for JSON; `codeField` for columns | Persistence: Sandbox 66. Foundation: RunnerProtocol 107, 108; ControlProtocol 150, 152; EvidenceModel 35, 42. Effects: Claude 49, 50; `ProviderStopped`, `Helper*`. Application: CommandCenter 49; ControlPane 341. Web: Json 78, 114, 126, 144, 165, 167, 169; `FormErrors` |
| B33 | Database config types (Foundation/SystemConfig): `Hostname`, `PgIdentifier` | host: non-empty, no whitespace; database/user: PostgreSQL identifier (≤63 bytes) | no | Foundation: SystemConfig 51, 53, 54 (pinned), 89, 91, 92 (raw decode) |
| B34 | `OutputTail` and `RoleText` (Kernel) — bounded-text candidates | `OutputTail`: ≤2000 characters (`Engine.hs:248 tailOf`, lenient UTF-8); `RoleText`: 1–4000, newline/tab only (`textValid`, `Roles.hs:195`) | `bounded-text` is **not** in package.yaml; `non-empty-text` is (gives non-emptiness only). Either add a bounded-text dependency or a Kernel `BoundedText` newtype with a smart constructor | the C fields marked "≤2000" / "≤4000" below |

Types that **exist** and are missing only a parser or a move (A): `MessageKind` (no `parseMessageKind`; use
`parseEnumText messageKindName`), `RequestKind` (decode `kind` + `choices` together), `Principal` (`parsePrincipal`
for the lower-case spelling; `principalLabel` for the conversation spelling — two spellings, both pinned),
`IdempotencyKey`/`Actor`/`Outcome`/`Revision` (Application/Command → Kernel), `ReceiptOutcome`
(Application/Decisions → Kernel), `Sha256` (needs `parseSha256Hex`; or unify with `ContentDigest`).

## 3. Per-module tables

Columns: line, field, declared type (abbreviated: `T` = `T.Text`), category, target type and note. "Row" marks a
Persistence row. Pins are cited in §4 and repeated here only as the file for orientation.

### 3.1 Kernel (64 record fields)

**Kernel/Profile.hs** — `RawGate`/`RawSpecialization`/`RawProfile` are the deliberate pre-validation input of
`mkGate`/`mkProfileDefinition` (refusal codes for bad values are pinned); the typed values already live in `Gate`.
Keep raw while pinned.

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 372 | rawGateId | T | A/E | `GateId` (ProfileTest, PolicyTest, SchedulerFixtures, ProfileDocumentTest) |
| 373 | rawGateStage | T | A/E | `GateStage` |
| 374 | rawGateArtifacts | [T] | A/E | `[ArtifactKind]` |
| 375 | rawGateKinds | Maybe [T] | A/E | `[WorkOrderKind]` |
| 376 | rawGateClasses | Maybe [T] | A/E | `[ClassTag]` |
| 377 | rawGatePathClasses | Maybe [T] | A/E | `[PathClass]` |
| 378 | rawGateVerifiers | [T] | A/E | `[VerifierKind]` |
| 379 | rawGateApproval | T | A/E | `Approval` |
| 386 | rawWhenKind | Maybe T | A/E | `WorkOrderKind` |
| 387 | rawWhenClass | Maybe T | A/E | `ClassTag` |
| 388 | rawSpecializationProfile | T | A/E | `ProfileId` |
| 394 | rawProfileId | T | A/E | `ProfileId` |
| 397 | rawInvariantExceptions | [T] | A/E | `[UniversalInvariant]` |
| 995 | bApprover | T | B | B14 `Approver`; not pinned |

**Kernel/Repository.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 82 | remoteName | T | B/E | B6 `GitRemoteName` |
| 83 | remoteFetchUrls | [T] | A/E | raw git-config URLs; parsed to `RemoteLocator` by `parseRemoteUrl` (the refusal names the raw URL) — keep as boundary input |
| 84 | remotePushUrls | [T] | A/E | as above |
| 90 | authoritativeName | T | B/E | B6 |
| 100 | observedCommonDir | T | B/E | B2 `AbsolutePath` |
| 103 | observedOtherRemotes | [T] | B/E | B6 |

**Kernel/GitBasis.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 52 | entryPath | T | B/E | B3 `TreePath` |
| 54 | entryBlob | T | B/E | B4 `BlobId` |
| 63 | changePath | T | B/E | B3 `TreePath` |

**Kernel/Effect.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 172 | requestParameters | T | D/E | effect parameters: digested (`intentParametersDigest`) and stored byte-exact; `validParameters` 1–4096, no control (`Effect.hs:301`) |
| 178 | leaseOwner | T | B/E | B8 `LeaseOwner` |
| 211 | reasonText | T | C | reason as stored, with the attestation marker; no bound; not pinned |
| 257 | intentParameters | T | D/E | as 172 |

**Kernel/Policy.hs** — `CheckRow` is a checklist row of words derived from a typed `Gate` (display text).

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 139 | rowCheck | T | A/E | `GateId` |
| 140 | rowWhen | T | C/E | words from `GateStage` |
| 141 | rowNeeds | [T] | C/E | words from `ArtifactKind` |
| 142 | rowCheckedBy | [T] | C/E | words from `VerifierKind` |
| 143 | rowApproval | T | C/E | words from `Approval` |
| 144 | rowWaivable | T | C/E | fixed sentences |
| 145 | rowAppliesTo | T | C/E | composed sentence |

**Kernel/Recovery.hs** — 39 recoveryOwner `T` B/E (B8 `LeaseOwner`).

**Kernel/Task.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 144 | dependencyTitle | T | A/E | `TaskTitle` |
| 145 | dependencyState | T | A/E | `TaskState` (the unknown-name case is `StateUnrecognised`) |
| 151 | factState | T | A/E | `TaskState` |
| 152 | factBlockReason | Maybe T | C/E | block reason (Ticket's) |

**Kernel/Roles.hs** — the decoded role answers; `checkAnswer` validates them with pinned codes.

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 60 | citationPath | T | B/E | B3 `TreePath` |
| 69 | checkArgv | [T] | B/E | B9 `RoleArgv` |
| 70 | checkSignature | T | B/E | B10 `FailureSignature` |
| 77 | discoverySummary | T | C/E | ≤4000 (`textValid`) — B34 `RoleText` |
| 78 | discoveryHypothesis | T | C/E | ≤4000 |
| 81 | discoveryAllowedPaths | [T] | B/E | B3 |
| 99 | testPath | T | B/E | B3 `ProtectedPath` |
| 100 | testContent | T | D/E | test file bytes (≤262144, no NUL); digested into `contractTestSha256` |
| 102 | testArgv | [T] | B/E | B9 |
| 103 | testSignature | Maybe T | B/E | B10 |
| 109 | criterionId | T | B/E | B11 `CriterionId` |
| 110 | criterionText | T | C/E | ≤4000 |
| 111 | criterionTicketQuote | T | C/E | ≤4000; must be grounded in the ticket |
| 120 | candidateAllowedPaths | [T] | B/E | B3 |
| 121 | candidateVerification | [[T]] | B/E | `[RoleArgv]` |
| 128 | filePath | T | B/E | B3 |
| 129 | fileText | T | D/E | mutant file bytes (≤262144) |
| 142 | findingRequirement | T | B/E | B11 |
| 143 | findingClaim | T | C/E | ≤4000 |
| 161 | implementationSummary | T | C/E | ≤4000 |
| 182 | reviewReasons | [T] | C | 1–20 reasons, each ≤4000; not pinned |

**Kernel/Runner.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 47 | runArgv | [T] | B/E | B9 `RunArgv` |
| 48 | runDirectory | T | B/E | B2 `AbsolutePath` |
| 49 | runEnvironment | [(T, T)] | B/E | B12 `EnvName` + bounded value |

**Kernel/WorkUnitLifecycle.hs** — 98 verifiedChecks `NonEmpty (T, CheckOutcome)` B (B13 `CheckName`; the test reads
only `snd`, `LifecyclePropertyTest.hs:324`).

### 3.2 Foundation (34 record fields)

**Foundation/RunnerProtocol.hs** (signed helper protocol; Foundation cannot use Kernel types)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 75 | runnerRun | T | B/E | B7 `RunName` |
| 77 | runnerArgvDigest | Maybe T | A/E | `Sha256` (needs a hex parser) |
| 105 | runnerResultId | T | A/E | `RequestId` |
| 106 | runnerResultOp | T | A/E | `RunnerOp` (`runnerOpName`) |
| 107 | runnerOutcome | T | B/E | B32 `RunnerOutcomeCode` |
| 108 | runnerReason | T | B/E | `Maybe HelperReasonCode` (`-` is "none") |
| 111 | runnerFields | [(T, T)] | D/E | the signed `field` lines as received; keep, interpret by key |

**Foundation/EvidenceModel.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 33 | evidenceLocator | T | C/E | locator text (`db:lockstep_jobs/7`) |
| 34 | evidenceSha256 | T | A/E | `Sha256`; note the pin uses non-hex `"abc123"` (`CommandCenterViewTest.hs:118`), so typing breaks it |
| 35 | evidenceKind | T | B/E | B32 `EvidenceKind` |
| 36 | evidenceProducer | T | C/E | producer label |
| 42 | revisionCommit | T | B/E | not a commit: `"schema 5"` — a tested-revision label |
| 49 | rowCriterion | T | C/E | |
| 50 | rowStatement | T | C/E | |
| 51 | rowSourceRefs | [T] | C/E | |
| 53 | rowMethod | T | C/E | |
| 54 | rowExpected | T | C/E | |
| 55 | rowActual | Maybe T | C/E | |

**Foundation/ControlProtocol.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 149 | resultId | T | A/E | `RequestId` |
| 150 | resultOp | T | B/E | B32 `OpName` (results of every helper protocol share this record) |
| 152 | resultReason | Maybe T | B/E | `HelperReasonCode` |
| 155 | resultFields | [(T, T)] | D/E | signed field lines |
| 156 | resultDetail | T | C/E | helper's detail line |

**Foundation/FolderProtocol.hs** — 60 folderExpect `T` B/E (the folder-list token `folders-<hex>`; a typed digest
prefix); 61 folderPath `T` B/E (B2, Foundation's own `FolderPath`).

**Foundation/SystemConfig.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 51 | dbHost | T | B/E | B33 `Hostname` |
| 53 | dbName | T | B/E | B33 `PgIdentifier` |
| 54 | dbUser | T | B/E | B33 |
| 89 | rawHost | T | B | raw decode shape; validate with `FC.validate` into B33 |
| 91 | rawName | T | B | as above |
| 92 | rawUser | T | B | as above |
| 93 | rawPassword | T | A | `Secret` (decode straight into it) |
| 94 | rawDatabaseExtra | Map T AnyJSON | D | unknown-key capture, reported verbatim |
| 100 | rawSystemExtra | Map T AnyJSON | D | as above |

### 3.3 Persistence (156 record fields; every record here is a row or a row's write shape)

Unless noted, every `Text` column is read with `O.unboundedTextField` — no typed decoder exists to throw away; the fix
is a `codeField`/typed field. Typed decoders that *are* discarded are marked **[discarded]**. No Persistence row is
pinned except `Migration`.

**Persistence/Jobs.hs** (row) — 83 jobRowError `Maybe T` C (failure message; no bound).

**Persistence/Profiles.hs** (rows `ProfileRow`, `NewProfileDecision`; `profile_id` already `codeField` at :105)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 58 | profileRowDigest | T | A | `ContentDigest` (CHECK 64-hex, `Migrations.hs:151`) |
| 59 | profileRowDocument | T | D | the profile document; its digest is over these bytes |
| 68 | profileDecisionOperation | T | B | B28 `ProfileOperation` |
| 69 | profileDecisionProfile | Maybe T | D | the id *as requested* (a refused request may not be an id) — documented `Profiles.hs:62-65` |
| 71 | profileDecisionDigest | Maybe T | A | `ContentDigest` |
| 72 | profileDecisionEngineer | Maybe T | B | B1 `EngineerName` |
| 74 | profileDecisionOutcome | T | B | B28 `ProfileDecisionOutcome` |
| 75 | profileDecisionRefusal | Maybe T | B | B29 `ProfileRefusalCode` |

**Persistence/Projects.hs** (rows; `setup` already `codeField`)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 39 | rowName | T | A | `ProjectName` (CHECK 1–80, `:417`) |
| 40 | rowOutcome | T | A | `ProjectOutcome` (≤2000, `:418`) |
| 42 | rowRefusal | Maybe T | B | B29 `ProjectSetupRefusal` |
| 43 | rowFolder | Maybe T | B | B2 |
| 44 | rowEngineerName | Maybe T | B | B1 |
| 46 | rowCreationDigest | Maybe T | A | `ContentDigest` (CHECK `:494`) |
| 55 | newProjectKey | T | A | `IdempotencyKey` (CHECK `:416`; move to Kernel) |
| 56 | newProjectName | T | A | `ProjectName` |
| 57 | newProjectOutcome | T | A | `ProjectOutcome` |
| 58 | newProjectDigest | T | A | `ContentDigest` |

**Persistence/Tasks.hs** (rows)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 52 | rowTitle | T | A | `TaskTitle` (Kernel ≤200; no column CHECK) |
| 53 | rowAcceptance | T | C | ≤4000 (CHECK `:440`, `mkAcceptance`) — bounded-text candidate |
| 56 | rowCreationDigest | Maybe T | A | `ContentDigest` |
| 66 | newTaskKey | T | A | `IdempotencyKey` |
| 67 | newTaskAcceptance | T | C | ≤4000 |
| 69 | newTaskDigest | T | A | `ContentDigest` |

**Persistence/Commands.hs** (rows)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 39 | rowKey | T | A | `IdempotencyKey` |
| 40 | rowKind | T | B | B27 `CommandKind` |
| 41 | rowDigestHex | T | A | **[discarded]** `digestField` bytes rendered by `hexDigest` (`Commands.hs:117`); keep `Sha256`/bytes |
| 42 | rowActor | T | A | `Actor` (`parseActor`; move to Kernel) |
| 44 | rowOutcome | T | A | `Outcome` (CHECK `:72`; move to Kernel) |
| 53 | newKey | T | A | `IdempotencyKey` |
| 55 | newKind | T | B | B27 |
| 57 | newActor | T | A | `Actor` |
| 59 | newOutcome | T | A | `Outcome` |

**Persistence/Transactions.hs** (rows; `state`/`stage`/`halt_code` decoded together by `marshallPartial`, record
`kind`/`stage` and invocation `stage` are `codeField`)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 98 | txRowEngineer | T | B | B1 |
| 99 | txRowFolder | T | B | B2 |
| 110 | txRowBasis | Maybe T | A | `CommitId` (CHECK 40-hex `:590`) |
| 111 | txRowBranch | Maybe T | B | B5 `WorkBranch` |
| 112 | txRowFreeze | Maybe T | A | `CommitId` |
| 113 | txRowCandidate | Maybe T | A | `CommitId` |
| 114 | txRowAccepted | Maybe T | A | `CommitId` |
| 115 | txRowContract | Maybe T | A | `ContentDigest` |
| 127 | recordRowPrincipal | T | A | `Principal` (CHECK `:608`) |
| 129 | recordRowBody | T | D | Fleece record body; `body_digest` is its SHA-256 (≤4 MiB) |
| 130 | recordRowDigest | T | A | `ContentDigest` |
| 139 | invocationRowWhat | T | B | B25 `InvocationSubject` |
| 140 | invocationRowRunner | T | B | B23 `RunnerName` |
| 141 | invocationRowAdapter | T | B | B24 `AdapterName` |
| 142 | invocationRowArgv | T | D | JSON argv encoding (`argvText`); compared by a trigger |
| 143 | invocationRowOutcome | Maybe T | A | `RoleEnding` or `CommandEnding` (one column, both encodings; typed at the Application boundary per progress.md) |
| 148 | invocationRowStdoutDigest | Maybe T | A | `ContentDigest`/`Sha256` |
| 149 | invocationRowStderrDigest | Maybe T | A | as above |
| 150 | invocationRowStdoutTail | Maybe T | C | ≤2000 (`tailOf`) — B34 `OutputTail` |
| 151 | invocationRowStderrTail | Maybe T | C | ≤2000 |
| 154 | invocationRowAnswer | Maybe T | D | role answer document (≤262144 octets, CHECK `:658`), digested |
| 156 | invocationRowAnswerDigest | Maybe T | A | `ContentDigest` |
| 166 | finishOutcome | T | A | as 143 |
| 171 | finishStdoutDigest | Maybe T | A | as 148 |
| 172 | finishStderrDigest | Maybe T | A | as 148 |
| 173 | finishStdoutTail | Maybe T | C | ≤2000 |
| 174 | finishStderrTail | Maybe T | C | ≤2000 |
| 175 | finishAnswer | Maybe T | D | as 154 |
| 177 | finishAnswerDigest | Maybe T | A | `ContentDigest` |
| 585 | factEngineer | T | B | B1 |
| 586 | factFolder | T | B | B2 |

**Persistence/Repositories.hs** (rows; `observation_digest` read typed by `digestField`)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 56 | rowOwnerName | T | B | B1 |
| 57 | rowCommonDir | T | B | B2 |
| 58 | rowPhysicalId | T | A | `PhysicalId` (`physicalText` "dev:inode") |
| 59 | rowRemoteName | Maybe T | B | B6 |
| 60 | rowRemoteIdentity | Maybe T | A | `RemoteIdentity` comparison key (`remoteIdentityText`; a local one drops its display path) |
| 61 | rowOtherRemotes | T | D | encoded list of remote names; decode to `[GitRemoteName]` |
| 68 | decisionOperation | T | B | B28 `IdentityOperation` |
| 69 | decisionEngineerName | T | B | B1 (as requested; a refused name may not match — decide like 70) |
| 70 | decisionPath | Maybe T | D | path *as requested*, audit record |
| 71 | decisionRemote | Maybe T | D | remote *as requested* |
| 72 | decisionRefusal | Maybe T | B | B29 `RegistrationRefusalCode` |
| 75 | decisionObservation | Maybe T | D | rendered observation (evidence) |
| 84 | engineerEntryName | T | B | B1 |

**Persistence/Migration.hs** — 44 migrationDescription `T` C/E; 45 migrationSql `T` D/E (checksummed SQL text).

**Persistence/Execution.hs** (rows)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 46 | enablementRowKey | T | A | `IdempotencyKey` |
| 47 | enablementRowDigest | T | A | `ContentDigest` |
| 50 | enablementRowEngineer | T | B | B1 |
| 51 | enablementRowFolder | T | B | B2 |
| 54 | enablementRowProfileDigest | T | A | `ContentDigest` |
| 55 | enablementRowActor | T | B | B15 `HumanEvidence` |
| 56 | enablementRowAt | T | A | `UTCTime` (rendered "to the second" in SQL; render at the edge) |
| 61 | admissionRowKey | T | A | `IdempotencyKey` |
| 62 | admissionRowDigest | T | A | `ContentDigest` |
| 66 | admissionRowEffectiveDigest | T | A | `ContentDigest` |
| 67 | admissionRowActor | T | B | B15 |
| 68 | admissionRowAt | T | A | `UTCTime` |

**Persistence/DecisionReceipts.hs** (row)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 28 | receiptRowKey | T | A | `IdempotencyKey` |
| 29 | receiptRowDigest | T | A | `ContentDigest` |
| 31 | receiptRowChoice | T | B | B18 `DecisionChoiceName` |
| 33 | receiptRowOutcome | T | A | `ReceiptOutcome` (move to Kernel) |
| 34 | receiptRowRefusal | Maybe T | B | B29 |
| 35 | receiptRowActor | T | B | B15 |
| 36 | receiptRowBasis | Maybe T | D | ledger-basis token compared for currency (`Decisions.hs:200`) |

**Persistence/Sandbox.hs** (rows) — 50 sandboxKeyParameters `T` D (effect parameters as applied); 66 sandboxOutcome
`T` B (B32 `SandboxOutcome`).

**Persistence/CommandCenter.hs** (read rows; `JobState` already typed)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 46 | activityKind | T | B | B27 |
| 47 | activityOutcome | T | A | `Outcome` |
| 48 | activityActor | T | A | `Actor` |
| 61 | evidenceError | Maybe T | C | job error message |
| 62 | evidenceDigestHex | Maybe T | A | **[discarded]** bytea read then `hexDigest` (`CommandCenter.hs:121`) |

**Persistence/Conversation.hs** (rows)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 38 | requestRowKey | T | A | `IdempotencyKey` |
| 39 | requestRowDigest | T | A | `ContentDigest` |
| 41 | requestRowEngineer | T | B | B1 |
| 42 | requestRowContract | Maybe T | A | `ContentDigest` (CHECK `:541`) |
| 43 | requestRowKind | T | A | `RequestKind` (decode with `choices`) |
| 44 | requestRowChoices | T | D | encoded choice list (`''` for a clarification); decode to `[Choice]` |
| 45 | requestRowQuestion | T | C | 1–4000 (CHECK `:544`) |
| 46 | requestRowEvidence | T | C | 1–4000 |
| 47 | requestRowAuthority | T | C | 1–4000 |
| 49 | requestRowState | T | B | B17 `RequestStateName` |
| 50 | requestRowAnswer | Maybe T | A | `Choice` |
| 60 | messageRowKey | T | A | `IdempotencyKey` |
| 61 | messageRowDigest | T | A | `ContentDigest` |
| 62 | messageRowKind | T | A | `MessageKind` (CHECK `:561`; add a parser) |
| 63 | messageRowPrincipal | T | A | `Principal` (label spelling) |
| 64 | messageRowEvidence | T | B | B15 `SenderEvidence` |
| 65 | messageRowChannel | T | B | B16 `MessageChannel` |
| 67 | messageRowBody | T | C | message text (Kernel ≤4000 after trim, `checkRequestText`); no column CHECK |
| 68 | messageRowChoice | Maybe T | A | `Choice` |

**Persistence/Ledger.hs** (rows; `kind`, intent state/class, source level, resolution basis already `codeField`)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 142 | subjectRowState | T | B | B30: `TaskState` for a ticket, `WorkOrderStateName` for a work order, decoded with `kind` |
| 227 | eventRowPrincipal | T | A | `Principal` (CHECK `:236`) |
| 228 | eventRowCommand | T | D | EventCodec line, replayed |
| 229 | eventRowStateAfter | T | B | B30 |
| 282 | refusalPrincipal | T | A | `Principal` |
| 283 | refusalCommand | T | D | EventCodec input text |
| 284 | refusalCode | T | B | B29 `TransitionRefusalCode` |
| 316 | ticketRowTitle | T | A | `TaskTitle` |
| 367 | workOrderRowKind | T | A | `WorkOrderKind` (no CHECK; `parseWorkOrderKind`) |
| 373 | workOrderRowClasses | T | D | encoded `[ClassTag]` |
| 374 | workOrderRowPathClasses | T | D | encoded `[PathClass]` |
| 375 | workOrderRowNonBehavioural | Maybe T | C | rationale (part of `NonBehaviouralBasis`) |
| 376 | workOrderRowApprover | T | B | B14 `Approver` |
| 377 | workOrderRowEffectiveDigest | T | A | `ContentDigest` (CHECK `:211`) |
| 378 | workOrderRowBindingDigest | T | A | `ContentDigest` |
| 459 | sourceRowDigest | T | A | `ContentDigest` |
| 510 | intentRowKey | T | A | `EffectKey` (CHECK `:256`) |
| 512 | intentRowSpecName | T | B | B31 `EffectSpecName` |
| 519 | intentRowParameters | T | D | parameters, digested |
| 520 | intentRowParametersDigest | T | A | `ContentDigest` |
| 527 | intentRowLeaseOwner | Maybe T | B | B8 |
| 529 | intentRowOutcome | Maybe T | C | outcome reason as stored (with attestation marker) |
| 741 | observationRowText | T | D | canonical observation line (`applied result="ok"`) |
| 743 | observationRowRefusal | Maybe T | B | B29 `ObservationRefusal` (`stale-claim`, `already-settled`) |
| 837 | recoveryRowDecision | T | D | canonical recovery line |
| 883 | resolutionRowDecision | T | D | canonical resolution line |
| 913 | evidenceRowArtifact | T | A | `ArtifactKind` |
| 914 | evidenceRowDigest | T | A | `ContentDigest` (CHECK `:313`) |
| 915 | evidenceRowVerifiers | T | D | encoded `[VerifierKind]` |
| 916 | evidenceRowApproval | T | A | `Approval` (CHECK `:315`) |
| 979 | workUnitRowPlanRef | Maybe T | A | `PlanRef` |

### 3.4 Application (245 record fields)

**Application/Repositories.hs** — 108 engineerRecordName B (B1); 114 repositoryRecordOwner B/E (B1); 115
repositoryRecordAuthoritative `Maybe (T, T)` B (B6 + `RemoteIdentity`); 116 repositoryRecordCommonDir B (B2); 121
registrationEngineer B (B1); 123 registrationRemote `Maybe T` B (B6).

**Application/Executor.hs** — 41 executorOwner B/E (B8).

**Application/CommandCenter.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 48 | summarySection | T | C | display heading |
| 49 | summaryStatus | T | B | B32 `SummaryStatus` (`JobState` or `Outcome` by section) |
| 51 | summaryDescription | T | C | display |
| 57 | activityKind | T | B | B27 |
| 58 | activityOutcome | T | A | `Outcome` |
| 59 | activityActor | T | A | `Actor` |
| 62 | activityJobState | Maybe T | A | **[discarded]** `Maybe JobState` re-rendered (`CommandCenter.hs:146`) |
| 77 | centerSchema | T | A | `MigrationId` (schema version) |

**Application/Execution.hs** (pinned by `ExecutionTest`)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 118 | enablementProject | T | A/E | `ProjectId` |
| 120 | enablementEngineer | T | B/E | B1 |
| 121 | enablementFolder | T | B/E | B2 |
| 122 | enablementChecks | T | A/E | `ProfileId` |
| 124 | enablementChecksDigest | T | A/E | `ContentDigest` |
| 125 | enablementActor | T | B/E | B15 |
| 126 | enablementAt | T | A | `UTCTime`; not pinned |
| 141 | admissionTask | T | A/E | `TaskId` |
| 142 | admissionProject | T | A/E | `ProjectId` |
| 143 | admissionWorkOrder | T | A/E | `WorkOrderId` |
| 144 | admissionEffectiveDigest | T | A/E | `ContentDigest` |
| 145 | admissionActor | T | B/E | B15 |
| 146 | admissionAt | T | A | `UTCTime`; not pinned |

**Application/Dispatcher.hs** — 51 jobError `Maybe T` C.

**Application/ControlPane.hs** — 340 folderListDigest A (`Sha256`); 341 folderListEntries `[(T, T)]` B (B32
`FolderMode` + B2).

**Application/EngineEvidence.hs** (page view of records)

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 44 | checkCommand | [T] | B | B9 |
| 47 | checkStdout | T | C | ≤2000 |
| 48 | checkStderr | T | C | ≤2000 |
| 63 | findingRequirementId | T | B | B11 |
| 64 | findingClaimText | T | C | ≤4000 |
| 72 | reviewCommit | T | A | `CommitId` |
| 74 | reviewReasons | [T] | C | ≤4000 each |
| 84 | evidenceCommands | [[T]] | B | `[RoleArgv]` |
| 88 | evidencePassed | Maybe (T, Bool) | A | `CommitId` |

**Application/ProfileDocument.hs** — `DocGate`/`DocSpecialization`/`DocProfile` decode documents into the pinned
`Raw*`; typing them moves refusals out of `mkGate` (pinned codes), so they follow `Raw*`. `GateDocument` is the
writer of built-in documents and is free to type (bytes unchanged when rendered through the same names).

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 25 | docGateId | T | A | `GateId` |
| 26 | docGateStage | T | A | `GateStage` |
| 27 | docGateArtifacts | [T] | A | `[ArtifactKind]` |
| 28 | docGateKinds | Maybe [T] | A | `[WorkOrderKind]` |
| 29 | docGateClasses | Maybe [T] | A | `[ClassTag]` |
| 30 | docGatePathClasses | Maybe [T] | A | `[PathClass]` |
| 31 | docGateVerifiers | [T] | A | `[VerifierKind]` |
| 32 | docGateApproval | T | A | `Approval` |
| 34 | docGateExtra | Map T AnyJSON | D | unknown keys |
| 39 | docWhenKind | Maybe T | A | `WorkOrderKind` |
| 40 | docWhenClass | Maybe T | A | `ClassTag` |
| 41 | docSpecializationProfile | T | A | `ProfileId` |
| 42 | docSpecializationExtra | Map T AnyJSON | D | |
| 47 | docId | T | A | `ProfileId` |
| 50 | docInvariantExceptions | Maybe [T] | A | `[UniversalInvariant]` |
| 53 | docExtra | Map T AnyJSON | D | |
| 119 | gateDocumentId | T | A | `GateId` |
| 120 | gateDocumentStage | T | A | `GateStage` |
| 121 | gateDocumentArtifacts | [T] | A | `[ArtifactKind]` |
| 122 | gateDocumentKinds | Maybe [T] | A | `[WorkOrderKind]` |
| 123 | gateDocumentClasses | Maybe [T] | A | `[ClassTag]` |
| 124 | gateDocumentVerifiers | [T] | A | `[VerifierKind]` |
| 125 | gateDocumentApproval | T | A | `Approval` |

**Application/Profiles.hs** — 95 storedDigest A (`ContentDigest`); 100 resolveRequestEngineer B (B1); 101
resolveRequestKind A (`WorkOrderKind`); 102 resolveRequestClasses A (`[ClassTag]`); 103 resolveRequestPathClasses A
(`[PathClass]`); 104 resolveRequestNonBehavioural `Maybe T` C (rationale). None pinned.

**Application/Activity.hs** — 21 activityRaw D (`renderProjection`, the §4 canonical text); 22 activityTime A
(`UTCTime`, rendered `projectionTimeText`).

**Application/EngineRecords.hs** — Fleece record bodies, stored and digested (`body_digest`). Typing them through
`FC.boundedEnum`/`FC.validate` renders the same text, so stored bodies stay byte-identical; none is pinned.

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 107 | startedWorkOrder | T | A | `WorkOrderId` |
| 108 | startedEngineer | T | B | B1 |
| 109 | startedFolder | T | B | B2 |
| 124 | haltCode | T | A | `HaltCode` (`haltCodeText`/`haltCodeFromText`) |
| 137 | inputName | T | B | B21 `TxInputName` |
| 151 | resumeRequest | T | A | `HumanRequestId` |
| 152 | resumeChoice | T | B | B20 `HaltChoice` |
| 167 | completionChoice | T | B | B20 `CompletionChoice` |
| 168 | completionChannel | T | B | B16 |
| 169 | completionEvidence | T | B | B15 |
| 183 | unfinishedInvocations | [T] | A | `[InvocationId]` |
| 195 | refusalCode | T | B | B22 `StageRefusalCode` |
| 207 | basisCommit | T | A | `CommitId` |
| 208 | basisTree | T | B | B4 `TreeId` |
| 209 | basisBranch | T | B | B5 |
| 226 | reproductionCommand | Maybe [T] | B | B9 |
| 227 | reproductionSignature | Maybe T | B | B10 |
| 231 | reproductionStdout | Maybe T | C | ≤2000 |
| 232 | reproductionStderr | Maybe T | C | ≤2000 |
| 233 | reproductionInvocation | Maybe T | A | `InvocationId` |
| 252 | baselinePath | T | B | B3 `ProtectedPath` |
| 256 | baselineStdout | T | C | ≤2000 |
| 257 | baselineStderr | T | C | ≤2000 |
| 274 | findingRecordRequirement | T | B | B11 |
| 275 | findingRecordClaim | T | C | ≤4000 |
| 294 | freezeCommit | T | A | `CommitId` |
| 295 | freezeBranch | T | B | B5 |
| 296 | freezeContractDigest | T | A | `ContentDigest` |
| 312 | contractBasis | T | A | `CommitId` |
| 313 | contractFreeze | T | A | `CommitId` |
| 315 | contractAllowedPaths | [T] | B | B3 |
| 316 | contractVerification | [[T]] | B | B9 |
| 322 | contractCriterionId | T | B | B11 |
| 323 | contractCriterionText | T | C | ≤4000 |
| 328 | contractTestPath | T | B | B3 `ProtectedPath` |
| 329 | contractTestSha256 | T | A | `ContentDigest` |
| 330 | contractTestArgv | [T] | B | B9 |
| 362 | refusedCode | T | B | B22 |
| 363 | refusedPaths | [T] | B | B3 |
| 364 | refusedInvocation | T | A | `InvocationId` |
| 378 | implementationSummary | T | C | ≤4000 |
| 379 | implementationChanged | [T] | B | B3 |
| 380 | implementationCandidate | T | A | `CommitId` |
| 382 | implementationInvocation | T | A | `InvocationId` |
| 398 | runCommand | [T] | B | B9 |
| 401 | runStdout | T | C | ≤2000 |
| 402 | runStderr | T | C | ≤2000 |
| 418 | summaryCommit | T | A | `CommitId` |
| 432 | reviewCommit | T | A | `CommitId` |
| 434 | reviewReasons | [T] | C | ≤4000 each |
| 435 | reviewInvocation | Maybe T | A | `InvocationId` |
| 450 | acceptanceCommit | T | A | `CommitId` |
| 451 | acceptanceBranch | T | B | B5 |
| 452 | acceptanceFrom | T | A | `CommitId` |

**Application/Engine.hs** — views rendered from typed rows (`Engine.hs:273-274`); `viewKey :: TransactionId` already
sits beside the pinned text.

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 177 | recordKind | T | A/E | `RecordKind` |
| 178 | recordPrincipal | T | A/E | `Principal` |
| 179 | recordStage | T | A | `Stage`; not pinned |
| 180 | recordBody | T | D/E | the record body as stored |
| 187 | invocationStage | T | A/E | `Stage` |
| 188 | invocationWhat | T | B/E | B25 |
| 189 | invocationRunner | T | B/E | B23 |
| 190 | invocationAdapter | T | B/E | B24 |
| 191 | invocationArgv | T | D/E | argv encoding |
| 192 | invocationOutcome | Maybe T | A/E | `RoleEnding`/`CommandEnding` |
| 199 | viewId | T | A/E | `TransactionId` (`viewKey` exists) |
| 200 | viewWorkOrder | T | A/E | `WorkOrderId` |
| 202 | viewEngineer | T | B | B1; not pinned |
| 203 | viewFolder | T | B | B2; not pinned |
| 204 | viewState | T | A/E | `StateName` [discarded `TxState`] |
| 205 | viewStage | T | A/E | `Stage` [discarded] |
| 206 | viewHalt | Maybe T | A/E | `HaltCode` |
| 207 | viewBasis | Maybe T | A/E | `CommitId` |
| 208 | viewBranch | Maybe T | B/E | B5 |

**Application/ProjectChecks.hs** — 93 choiceId A/E (`ProfileId`, rendered); 95 choiceDigest A/E (`ContentDigest`);
104 rulesDigest A/E (`ContentDigest`); 105 rulesSources `[(T, T, Int, T)]` A/E (`LayerLevel`, `ProfileId`,
`ContentDigest`); 113 rulesOutcome `Either T EffectiveRules` B/E (B29 code); 125 entryOrder A/E (`WorkOrderId`); 126
entryTitle A/E (`TaskTitle`); 139 checksQueue `Either T [QueueEntry]` B/E (B29 code).

**Application/Decisions.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 68 | stoppedReason | T | C/E | halt reason |
| 69 | stoppedTitle | T | A/E | `TaskTitle` |
| 78 | unknownStep | T | B/E | B31 `EffectSpecName` |
| 79 | unknownReason | T | C/E | outcome reason |
| 80 | unknownObservations | [T] | D | canonical observation lines; not pinned |
| 82 | unknownTitle | T | A/E | `TaskTitle` |
| 100 | receiptSubject | T | B/E | B19 `DecisionSubject` |
| 101 | receiptChoice | T | B/E | B18 |
| 103 | receiptOutcome | T | A/E | `ReceiptOutcome` (exists; `receiptApplied` compares text) |
| 104 | receiptRefusal | Maybe T | B/E | B29 |

**Application/Command.hs** — 270 workspaceName A/E (`WorkspaceName`); 298 receiptKey A/E (`IdempotencyKey`); 299
receiptKind B/E (B27).

**Application/Ledger.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 242 | receiptState | T | B/E | B30 state name |
| 250 | viewState | T | B | B30; `SubjectView`, not pinned |
| 552 | newEngineer | T | B/E | B1 |
| 556 | newClasses | [T] | A/E | `[ClassTag]` |
| 557 | newPathClasses | [T] | A/E | `[PathClass]` |
| 558 | newNonBehavioural | Maybe T | C/E | rationale |
| 801 | woBindingDigest | T | A/E | `ContentDigest` |
| 966 | scheduleRendering | T | D/E | canonical schedule rendering, digested |
| 967 | scheduleDigestText | T | A/E | `ContentDigest` |
| 1027 | previewOrders | [(…, T)] | A | `TaskTitle` |
| 1452 | storedObservation | T | D/E | canonical observation line |
| 1454 | storedRefusal | Maybe T | B/E | B29 |
| 1720 | recoveryDecision | T | D/E | canonical recovery line |
| 1835 | resolutionBasis | T | A/E | `ResolutionBasis` [discarded, `Ledger.hs:1851`] |
| 1836 | resolutionDecision | T | D/E | canonical resolution line |
| 1880 | factBinding | T | A | `ContentDigest` |
| 1888 | factTickets | [(TicketId, T, T, Int)] | A | `TaskTitle`, `TaskState` |
| 1890 | factRefusals | [(Uuid, Int, T, T, T)] | B | `Principal`, EventCodec text, B29 code |
| 1891 | factSchedule | Maybe (T, T) | D | rendering + digest |

**Application/LedgerView.hs** — 56 ticketLineTitle A/E (`TaskTitle`); 57 ticketLineState A/E (`TaskState`); 66
effectLineReason C/E; 79 orderLineBinding A/E (`ContentDigest`); 86 refusalLineSubject A/E (`Uuid`); 88
refusalLinePrincipal A/E (`Principal`); 89 refusalLineCommand D/E; 90 refusalLineCode B/E (B29); 100
projectionSchedule `Maybe (T, T)` D/E.

**Application/Conversation.hs**

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 101 | newRequestWorkOrder | T | A/E | `WorkOrderId` |
| 102 | newRequestEngineer | T | B/E | B1 |
| 103 | newRequestContract | Maybe T | A/E | `ContentDigest` |
| 104 | newRequestChoices | Maybe [T] | A/E | `[Choice]` |
| 105 | newRequestQuestion | T | C/E | 1–4000 |
| 106 | newRequestEvidence | T | C/E | 1–4000 |
| 107 | newRequestAuthority | T | C/E | 1–4000 |
| 113 | storedRequestId | T | A/E | `HumanRequestId` |
| 114 | storedWorkOrder | T | A/E | `WorkOrderId` |
| 115 | storedEngineer | T | B | B1; not pinned (whole-record `@?=` only) |
| 116 | storedContract | Maybe T | A | `ContentDigest`; not pinned |
| 117 | storedKind | T | A/E | `RequestKind` name |
| 118 | storedChoices | [T] | A/E | `[Choice]` |
| 119 | storedQuestion | T | C | 1–4000; not pinned |
| 120 | storedEvidence | T | C | 1–4000 |
| 121 | storedAuthority | T | C | 1–4000 |
| 123 | storedState | T | B/E | B17 |
| 124 | storedAnswer | Maybe T | A/E | `Choice` |
| 132 | messageKind | T | A/E | `MessageKind` |
| 133 | messagePrincipal | T | A/E | `Principal` (label spelling) |
| 134 | messageEvidence | T | B/E | B15 |
| 135 | messageChannel | T | B/E | B16 |
| 137 | messageBody | T | C/E | ≤4000 |
| 138 | messageChoice | Maybe T | A/E | `Choice` |
| 219 | detailsEngineer | T | B | B1 |
| 220 | detailsContract | Maybe T | A | `ContentDigest` |
| 221 | detailsChoices | Maybe [T] | A | `[Choice]` |
| 222 | detailsQuestion | T | C | 1–4000 |
| 223 | detailsEvidence | T | C | 1–4000 |
| 224 | detailsAuthority | T | C | 1–4000 |

**Application/Projects.hs** — 99 newProjectName A/E (`ProjectName`); 100 newProjectOutcome A/E (`ProjectOutcome`);
106 projectId A/E (`ProjectId`, `projectKey` exists); 107 projectName A/E; 108 projectOutcome A/E; 110 projectRefusal
B/E (B29); 111 projectFolder B/E (B2); 112 projectEngineer B/E (B1).

**Application/Tasks.hs** — 65 newTaskProject A/E (`ProjectId`); 66 newTaskTitle A/E (`TaskTitle`); 67
newTaskAcceptance C/E (≤4000); 69 newTaskDependencies A/E (`[TaskId]`); 74 editTitle A/E; 75 editAcceptance C/E; 77
editDependencies A/E; 89 taskId A/E (`taskKey` exists); 90 taskProject A/E; 91 taskTitle A/E; 92 taskAcceptance C/E;
94 taskState A/E (`TaskState`); 95 taskBlockReason C/E; 96 taskDependencies A/E.

### 3.5 Effects (34 record fields)

**Effects/Roles.hs** — `Doc*` are the role-answer decode shapes; `tExpect` and `fHint` are matched by hand
(`Roles.hs:680-683`, `:777-781`) where `FC.boundedEnum` would do it.

| Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| 91 | viewTree | T | B/E | B2 |
| 92 | viewInput | T | B/E | B2 |
| 93 | viewOutput | T | B/E | B2 |
| 104 | workspaceName | T | B/E | B7 `RunName` |
| 115 | runnerName | T | B/E | B23 |
| 311 | adapterName | T | B | B24 |
| 483 | kindValue | T | B | B26 `AnswerKind` |
| 538 | dKind | T | B | B26 |
| 539 | dSummary | T | C | ≤4000 (validated after decode) |
| 540 | dHypothesis | T | C | ≤4000 |
| 543 | dAllowed | [T] | B | B3 |
| 587 | crId | T | B | B11 |
| 588 | crText | T | C | ≤4000 |
| 589 | crQuote | T | C | ≤4000 |
| 608 | tPath | T | B | B3 `ProtectedPath` |
| 609 | tContent | T | D | test file bytes |
| 610 | tExpect | T | A | `Expectation` |
| 611 | tArgv | [T] | B | B9 |
| 612 | tSignature | Maybe T | B | B10 |
| 631 | cKind | T | B | B26 |
| 633 | cAllowed | [T] | B | B3 |
| 634 | cVerification | [[T]] | B | B9 |
| 720 | fRequirement | T | B | B11 |
| 721 | fClaim | T | C | ≤4000 |
| 726 | fHint | Maybe T | A | `FindingHint` |
| 747 | chKind | T | B | B26 |

**Effects/GitSupervisor.hs** — 172 basisCommit A/E (`CommitId`); 173 basisTree B (B4); 479 walkedPaths `Set T` B
(B3); 595 metaMessage C/E (commit message).

**Effects/HelperRunner.hs** — 78 preparedName B (B7; the test only passes it on, `HelperRunnerTest.hs:159`).

**Effects/Provider/Claude.hs** — 49 providerModel B/E (B32 `ClaudeModel`); 50 providerEffort B/E (B32 `Effort`).

**Effects/Scripted.hs** — 37 appliedParameters D (parameters as applied).

### 3.6 Web (28 record fields; snapshot — another agent is editing)

| Module:Line | Field | Type | Cat | Target / note |
|---|---|---|---|---|
| App:447 | formKey | T | A | `IdempotencyKey` (raw form shape; Web/Validation types it) |
| App:448 | formName | T | A | `ProjectName` |
| App:449 | formOutcome | T | A | `ProjectOutcome` |
| App:450 | formFolder | T | A | `FolderChoice` |
| App:451 | formPath | T | B | B2 |
| App:684 | haltRequestId | T | A | `HumanRequestId` |
| App:685 | haltChoice | T | B | B20 `HaltChoice` |
| App:748 | answerText | T | C | decision text, ≤500 (`checkDecisionText`, `DecisionTest.hs:97`) |
| TaskPages:60 | formTaskKey | T | A | `IdempotencyKey` |
| TaskPages:61 | formTaskTitle | T | A | `TaskTitle` |
| TaskPages:62 | formTaskAcceptance | T | C | ≤4000 |
| TaskPages:63 | formTaskPriority | T | A | `Priority` (Kernel/Task) |
| TaskPages:64 | formTaskDependencies | [T] | A | `[TaskId]` |
| Json:78 | errorCode | T | B | B29/B32 code |
| Json:90 | sessionToken | T | A | `RawToken` (Foundation/OperatorToken) |
| Json:102 | idValue | T | A | `RequestId` |
| Json:114 | urlValue | T | B | typed handover URL (from the route builders) |
| Json:126 | stateValue | T | B | B32 (`pending` \| `untrusted`) |
| Json:138 | folderBodyDigest | T | A | `Sha256` |
| Json:144 | folderMode | T | B | B32 `FolderMode` |
| Json:145 | folderPath | T | B | B2 |
| Json:165 | resultBodyState | T | B | B32 (`done`) |
| Json:166 | resultBodyId | T | A | `RequestId` |
| Json:167 | resultBodyOp | T | B | B32 `OpName` |
| Json:168 | resultBodyOutcome | T | A | `Outcome` (ControlProtocol) |
| Json:169 | resultBodyReason | Maybe T | B | `HelperReasonCode` |
| Json:172 | resultBodyFields | Map T T | D | helper fields as received |
| Json:173 | resultBodyDetail | T | C | helper detail |

### 3.7 Positional constructor fields (161)

| Module:Line | Constructor (Text slots) | Cat | Target / note |
|---|---|---|---|
| Web/Validation:66 | ValidationError T | C | message |
| Web/Validation:71 | FormErrors (Map T Error) | B | `FieldName` (Web/Fields declares names) |
| Foundation/EvidenceModel:26 | Inconclusive T | C/E | reason |
| Foundation/EvidenceModel:27 | Blocked T | C/E | reason |
| Foundation/EvidenceModel:28 | NotRun T | C/E | reason |
| Foundation/Json:20 | JString T | D/E | JSON value |
| Foundation/Json:27 | JRaw T | D | pre-rendered document, kept exactly |
| Foundation/SystemConfig:68 | ConfigUnknownKeys [T] | D/E | keys verbatim |
| Foundation/InstallProtocol:62 | CandidateDigest T | B | 16-hex SHA-256 prefix |
| Foundation/InstallProtocol:64 | RecoveryOf T | A | `RequestId`-shaped 32-hex id |
| Persistence/Integrity:22 | IntegrityViolation T | C | message |
| Application/Repositories:189 | Observed … (Maybe T) … | B | B6 |
| Application/Sandbox:83 | UnreadableParameters T | C | |
| Application/Executor:60-63 | RanApplied / RanNotApplied / RanExhausted / RanUnknown T (4) | C/E | result/reason text |
| Application/Reconciler:39,40,42 | ReconciledApplied / ReconciledNotApplied / StillUnknown T (3) | C/E | |
| Application/Reconciler:41 | ReconciledExhausted T | C | not pinned |
| Application/ProjectChecks:151 | ExpectProfile T | A/E | `ProfileId` (`"none"` is also used as a value) |
| Application/LedgerRefusal:47 | LedgerRefused T T | B/E | code (B29) + words |
| Application/LedgerRefusal:48 | LedgerIntegrity T | C/E | |
| Application/LedgerRefusal:49 | LedgerUnavailable T | B/E | code |
| Application/LedgerRefusal:282 | LedgerCorrupt T | C | |
| Application/LedgerRefusal:115 | NotDurable T | C | codec reason |
| Application/LedgerRefusal:125 | InvalidKind T | D | the kind as given |
| Application/LedgerRefusal:147 | UnknownSandboxEffect T [T] | D | as given + known names (B31) |
| Application/Tasks:82 | BlockTask T | C/E | reason |
| Application/Conversation:69 | SenderPlanner T | A/E | `InvocationId` (the pin uses `"inv-0001"`, not a UUID) |
| Application/Conversation:71 | SenderAgent T | B/E | agent label |
| Application/Engine:169 | Stepped T _ | B/E | B21 |
| Application/Engine:171 | Idle T _ | B/E | idle reason |
| Application/Engine:1055 | CommandNotRun T | B | code |
| Application/Engine:1060 | FinishNotRecorded T _ | B | code |
| Application/Profiles:83 | ProfileRefused T T _ | B | code + words |
| Application/Profiles:85 | ProfileIntegrity T | C | |
| Application/EngineWorker:51 | PassRefused T | B | code |
| Application/Database:96 | DatabaseCorrupt T | C | diagnosis |
| Effects/Roles:109 | RunnerRefused T | B/E | code |
| Effects/Roles:110 | RunnerUncertain T | B/E | code |
| Effects/Roles:341 | RoleFailed T _ | B | B22 code (pinned only as rendered `roleOutcomeCode` text) |
| Effects/Roles:342 | RoleUncertain T | B | B22 |
| Effects/Roles:495 | DocCitation T … | B | B3 |
| Effects/Roles:520 | DocCheck [T] T _ | B | B9, B10 |
| Effects/Roles:687 | DocFile T T _ | B | B3 + D content |
| Effects/Roles:704 | DocSupplement T T [T] T _ | B | B3, D, B9, B10 |
| Effects/Roles:785 | DocImplementation T T _ | B | B26 + C summary |
| Effects/Roles:802 | DocReview T T [T] _ | B | B26, `Verdict`, C reasons |
| Effects/Scripted:54-56 | StepApply / StepRefuse / StepApplyThenHang T (3) | C/E | scripted answers |
| Effects/Reconciler:24 | LookupApplied T | C/E | |
| Effects/HelperRunner:96 | HelperRefused T | B/E | `HelperReasonCode` |
| Effects/HelperRunner:99 | HelperResultInvalid T | B/E | the field name that failed |
| Effects/HelperRunner:100 | HelperRequestInvalid T | B/E | |
| Effects/Executor:25-26 | AnswerApplied / AnswerNotApplied T (2) | C/E | |
| Kernel/Effect:101 | EffectSpec T … | B | B31 (abstract; built by `mkEffectSpec`) |
| Kernel/Effect:185-187 | DestinationApplied / DestinationNotApplied / NoAnswer T (3) | C/E | |
| Kernel/Effect:191-192 | SettledApplied / SettledNotApplied T (2) | C/E | |
| Kernel/Effect:243-247 | IntentApplied / IntentNotApplied / IntentUnknown / IntentAbandoned T (4) | C/E | reasons; marker text pinned |
| Kernel/Effect:306 | IntentClaim T _ _ | B/E | B8 |
| Kernel/Effect:310 | IntentAbandon T | C/E | |
| Kernel/Effect:468, 471 | InvalidEffectSpec / InvalidEffectKey T (2) | C/E | |
| Kernel/Effect:478 | IllegalIntentTransition T T | A/E | `IntentStateName` + input name |
| Kernel/Repository:52, 53 | NetworkLocator T T / LocalLocator T (2) | B/E | host + normalized path / B2 |
| Kernel/Repository:60, 61 | NetworkIdentity T T / LocalIdentity _ T (2) | B/E | as above |
| Kernel/Repository:142 | GitFailed T | C/E | |
| Kernel/Repository:143-145 | AuthoritativeRemoteAmbiguous [T] / …Unknown T / …Inconsistent T (3) | B/E | B6 |
| Kernel/Repository:146, 147 | RemoteUrlUnsupported / RemoteUnresolvable T (2) | C/E | raw URL |
| Kernel/Reconciliation:56, 58 | LookupFound / LookupFailed T (2) | C/E | |
| Kernel/Reconciliation:114, 115 | AttestApplied / AttestNotApplied T (2) | C/E | |
| Kernel/Reconciliation:276, 279 | NothingToReconcile / NotUnknown T (2) | A/E | `IntentStateName` |
| Kernel/WorkUnitLifecycle:49 | FrozenContract _ T _ [T] | A/E | `ContentDigest` + B13 (via `mkFrozenContract`) |
| Kernel/WorkUnitLifecycle:104 | ReviewChangesRequested T | C/E | |
| Kernel/WorkUnitLifecycle:112 | Verified … [T] | B/E | B13 |
| Kernel/WorkUnitLifecycle:113 | Rework _ _ T | B/E | reason code |
| Kernel/WorkUnitLifecycle:115 | Halted T | C/E | |
| Kernel/WorkUnitLifecycle:134, 135 | WuGatePassed T / WuGateFailed T T (2) | B/E | B13 |
| Kernel/WorkUnitLifecycle:137 | WuHalt T | C/E | |
| Kernel/Scheduler:193, 194 | InvalidResource / ConflictingInput T (2) | C/E | |
| Kernel/Task:160, 162 | WaitingFor [T] / CannotStart [T] (2) | A/E | `TaskTitle` |
| Kernel/Task:161 | BlockedBecause T | C/E | |
| Kernel/Task:167 | StateUnrecognised T | D | the unknown stored name, verbatim |
| Kernel/Ticket:36 | Blocked T _ | C/E | reason |
| Kernel/Ticket:48 | TicketBlock T | C/E | |
| Kernel/Decision:32-35 | ItHappened / ItDidNotHappen / GiveUp _ _ T (3) | C/E | ≤500 (`checkDecisionText`) |
| Kernel/WorkOrder:76, 77, 101, 104 | Waiting _ T / Halted T / WoWait _ T / WoHalt T (4) | C/E | |
| Kernel/Conversation:126-130 | HumanSays / PlannerSays / HumanDecides (choice + text) / Revise / Withdraw (5) | C/E | ≤4000; `HumanDecides` choice is `Choice` |
| Kernel/Project:141 | ExistingFolder T | B/E | B2 |
| Kernel/Runner:184 | LaunchFailed T | B/E | code |
| Kernel/Runner:189 | ProviderStopped T | B/E | `ProviderStopCode` |
| Kernel/Runner:234, 236 | RoleEndedUncertain / RoleEndedFailed T (2) | B | B22 |
| Kernel/Delivery:62, 83 | NeedsReconciliation _ T / DelOutcomeUnknown T (2) | C/E | |
| Kernel/Policy:187 | LostCheck T | A/E | `GateId` |
| Kernel/Profile:678 | Override T T _ _ | B/E | B14 approver + C reason (via `mkOverride`) |
| Kernel/Profile:690 | NonBehaviouralBasis T T | C/E | rationale + B14 (via `mkNonBehaviouralBasis`) |
| Kernel/Profile:954 | ExceptionReceipt … T T … | C/E | reason + B14 (via `mkExceptionReceipt`) |
| Kernel/Profile:1092 | ProfileConfirmation _ _ T | B/E | B14 (via `mkProfileConfirmation`) |
| Kernel/Profile:1207, 1212, 1216, 1225, 1226 | InvalidProfile / ProfileConflict / NonBehaviouralRefused / InvalidRecord / InvalidFacts T (5) | C (ProfileConflict C/E) | 4 C, 1 C/E |
| Kernel/Profile:1208 | WeakensUniversalInvariant T | A | `UniversalInvariant` |
| Kernel/Profile:1210, 1211 | WeakensGate _ T / UnprovableStrengthening _ T (2) | B/E | the axis: a closed `Axis` sum |
| Kernel/EventCodec:54, 55 | TicketCreated / TicketRevised T (2) | A/E | `TaskTitle` |
| Kernel/EventCodec:146, 147 | Bare / Quoted T (2) | D | codec value representation |
| Kernel/Transition:47 | AlreadyTerminal T | A/E | state name |
| Kernel/Transition:48 | NotAuthorized _ T | B/E | input name |
| Kernel/Transition:49 | IllegalTransition T T | A/E | state + input names |
| Kernel/Transition:51 | BasisMismatch T | C/E | |
| Kernel/Transition:52 | KindForbids T | B/E | input name |
| Kernel/Recovery:132 | NothingToRecover T | C/E | |
| Kernel/Transaction:157, 160 | Halted _ T / Stopped T (2) | A/E | `HaltCode` |
| Kernel/Transaction:209, 211, 213 | HaltRoleFailed / HaltUncertainInvocation / HaltSupervisorFailed T (3) | B | B22 |
| Kernel/Transaction:456-477 | BasisRefused / CandidateRejected / ImplementationRefused / VerificationInconclusive / RoleFailed / RoleUncertain / SupervisorFailed / ScopeRefused T (8) | B/E | B22 |

## 4. Verified frozen pins (E)

All in frozen suites; line numbers are where the test constructs, matches or compares the field with `Text`.

### 4.1 Kernel
- `RawGate`/`RawSpecialization`/`RawProfile` (all 13 fields): unit `Kernel/ProfileTest.hs:137-154, 161, 171, 183,
  339-360, 389-413, 494-541, 686-688`; `Kernel/PolicyTest.hs:72-93, 177`; `Kernel/SchedulerFixtures.hs:138-155`;
  `Application/ProfileDocumentTest.hs:25-72`; `Kernel/ExecutionTest.hs:132, 159`.
- `RemoteConfig`: `Kernel/RemoteTest.hs:148`. `AuthoritativeRemote` (positional): `Kernel/RepositoryTest.hs:193`.
  `RepositoryObservation.observedCommonDir`: `RepositoryTest.hs:40, 185`; `observedOtherRemotes`: `:75, 87, 122, 188`.
- `TreeEntry.entryPath`/`entryBlob`: integration `GitSupervisorTest.hs:203, 216-217`. `Change` (positional, path):
  unit `Kernel/GitBasisTest.hs:66-73`; integration `GitSupervisorTest.hs:259-262, 323-361`;
  `SnapshotBoundsTest.hs:118-121`; stress `Main.hs:65`.
- `IntentRequest` (parameters): unit `EffectTest.hs:223-243`, `RemediationTest.hs:70`, `ReconciliationTest.hs:97`,
  `TraceTest.hs:349`, `RecoveryTest.hs:85`, `EffectViewTest.hs:73`, `Web/LedgerPageTest.hs:113`; integration
  `LedgerTest.hs:430`, `ActivityPageTest.hs:86`, `Support/Decisions.hs:80`, `ReconciliationTest.hs:474` and others.
  `Intent.intentParameters`: `EffectTest.hs:109, 245`; `ReconciliationTest.hs:236`; `RecoveryTest.hs:225`.
- `Lease` (owner): `EffectTest.hs:283-285, 333, 462-463`; `RecoveryTest.hs:217`; integration
  `RemediationTest.hs:315, 327`. `RecoveryInput.recoveryOwner`: `RecoveryTest.hs:137, 271`.
- `CheckRow` (all 7): `Kernel/PolicyTest.hs:139-158`.
- `DependencyFact`/`TaskFacts`: `Kernel/TaskTest.hs:43, 84, 94`.
- Roles records: `Kernel/RolesTest.hs:70-101` (Discovery, Candidate, Finding, Citation, Check, CandidateTest,
  Criterion, FileContent), `:125, 171-235` (updates and `Implementation`); integration `RolesTest.hs:95`.
- `RunSpec`: unit `Kernel/RunnerTest.hs:44-99`; integration `ProcessRunnerTest.hs:57-59, 172-187`.
- Positional: Effect reasons and `IntentClaim` (`EffectTest.hs:131-468`, `TraceTest.hs:357-399`,
  `RemediationTest.hs:84-227`, `ReconciliationTest.hs:114-364`, `RecoveryTest.hs:106-128, 283`,
  `EffectViewTest.hs:89-184`, `Web/LedgerPageTest.hs:125-128`; integration `LedgerTest.hs:263-302`,
  `ReconciliationTest.hs:155-392`, `ExecutorTest.hs:129-381`, `DecisionsTest.hs:118, 149`); Transition
  (`TransitionTest.hs:41-46, 74, 131`); Transaction `TxInput`/`TxState` (`TransactionTest.hs:116-191`,
  `CandidateTest.hs:106-117`); WorkUnit (`WorkUnitLifecycleTest.hs:64-189`, `LifecyclePropertyTest.hs:110, 238-318`);
  WorkOrder (`WorkOrderTest.hs:51-114`, `SchedulerTest.hs:432-456`, `SchedulerPropertyTest.hs:200-201`,
  `ActivityTest.hs:45, 91`); Task readiness (`TaskTest.hs:84-146`, `ExecutionTest.hs:189-191`, integration
  `TasksTest.hs:201, 224`); Ticket (`TicketTest.hs:46, 58, 88`, `EventCodecTest.hs:96-111`); Decision
  (`DecisionTest.hs:53-99`); Conversation inputs (`Kernel/ConversationTest.hs:76-192`, integration
  `ConversationTest.hs:173-287`); Delivery (`DeliveryTest.hs:56, 69, 126`); Repository refusals and locators
  (`RemoteTest.hs:59-143`, `RepositoryTest.hs:56-172`); `LostCheck` (`PolicyTest.hs:172-187`); Profile smart
  constructors (`ProfileTest.hs:265-267, 317, 544-549, 570, 628-644, 711, 747-750, 838, 854, 896-898`,
  `SchedulerTest.hs:269-272`, `SchedulerFixtures.hs:190`); `mkFrozenContract` (`WorkUnitLifecycleTest.hs:161-176`,
  `LifecycleFixtures.hs:149-151`); `ProviderStopped`/`LaunchFailed` (`ClaudeAdapterTest.hs:105-107`,
  `RunnerTest.hs:122`, `RunnerProtocolTest.hs:148`, `CandidateTest.hs:71`); `ExistingFolder`
  (`ProjectTest.hs:109`); `InvalidResource`/`ConflictingInput` (`SchedulerTest.hs:393`).

### 4.2 Foundation
- `RunnerRequest.runnerRun`/`runnerArgvDigest`: unit `Foundation/RunnerProtocolTest.hs:71-72`.
- `RunnerResult` (all five Text fields): `RunnerProtocolTest.hs:113-173`; `Effects/ClaudeAdapterTest.hs:121-127`.
- `ControlResult`: unit `ControlProtocolTest.hs:83-93, 210-232`; integration `ControlPaneTest.hs:174, 372-380`,
  `ControlHelperTest.hs:123-401`, `HandoverTest.hs:94, 116`, `InstallHelperTest.hs:98, 121`,
  `LifecycleHelperTest.hs:106-311`, `FolderHelperTest.hs:52-137`.
- `FolderRequest` (positional): unit `FolderProtocolTest.hs:80-82`; integration `Support/Folders.hs:268`.
- `EvidenceItem`, `TestedRevision` (positional), `RowInput`, `Disposition` reasons: unit `EvidenceModelTest.hs:34-164`;
  `Web/CommandCenterViewTest.hs:40-119`.
- `DatabaseConfig.dbHost/dbName/dbUser`: unit `SystemConfigTest.hs:31-34`; integration `Support/Postgres.hs:145-148`,
  `MigrationDbTest.hs:166, 172`. `ConfigUnknownKeys`: `SystemConfigTest.hs:44, 48`. `JString`: `RolesTest.hs:239, 242`.

### 4.3 Persistence
- `Migration.migrationSql`: unit `Persistence/MigrationTest.hs:45, 72`; integration `MigrationDbTest.hs:102`.
  `migrationDescription`: `MigrationTest.hs:72, 83`. No other Persistence row is touched by a frozen test.

### 4.4 Application
- `TransactionView`, `RecordView`, `InvocationView`: integration `EngineTest.hs:214-420`, `EngineHumanTest.hs:282-432`,
  `EngineRecoveryTest.hs:343-653`, `EngineRecoveryTwoTest.hs:362, 429`, `EngineCandidateTest.hs:289-457`,
  `EngineImplementTest.hs:278-425`, `EngineOwnershipTest.hs:194, 210`, `EngineHelperPathTest.hs:345-441`,
  `EnginePageTest.hs:318-487`, `LiveAdapterTest.hs:255-292`. Not pinned: `recordStage`, `viewEngineer`, `viewFolder`.
- `StepReport` (`Stepped`/`Idle`): `EngineHumanTest.hs:246-250` (test helper `inputOf`).
- `NewHumanRequest`: `ConversationTest.hs:101-108, 279-285`. `StoredRequest`: `storedRequestId`
  (`ConversationTest.hs:119-258`, `EngineHumanTest.hs:278-416`, `EngineRecoveryTest.hs:482`), `storedWorkOrder`
  (`EngineTest.hs:218`, `EngineHumanTest.hs:269`, `EngineCandidateTest.hs:293`, `EngineImplementTest.hs:385`,
  `EngineRecoveryTest.hs:475`), `storedKind/storedChoices/storedState/storedAnswer` (`ConversationTest.hs:172-231`,
  `EngineTest.hs:269-397`, `EngineHumanTest.hs:272, 316`). Not pinned: `storedEngineer`, `storedContract`,
  `storedQuestion`, `storedEvidence`, `storedAuthority` (only whole-record equality, `ConversationTest.hs:192, 253`).
  `StoredMessage`: `ConversationTest.hs:176-212`; `EngineHumanTest.hs:349`. `Sender*`: `ConversationTest.hs:149,
  216-225`; `EngineHumanTest.hs:364-374`.
- `NewProject` (positional): `ProjectsTest.hs:81`; `ConversationTest.hs:85`. `ProjectView`: `ProjectsTest.hs:90-205`,
  `ConversationTest.hs:93`, `ExecutionTest.hs:286`.
- `NewTask` (positional): `ConversationTest.hs:90`. `TaskEdit`: `TasksTest.hs:110, 158-171, 242`. `TaskView`:
  `TasksTest.hs:120-238`; `ConversationTest.hs:91, 94`; `ExecutionTest.hs:373, 436`. `BlockTask`:
  `TasksTest.hs:199-219`; `ExecutionTest.hs:361`.
- `Enablement`/`Admission`: `ExecutionTest.hs:243, 278-315, 373-439`; `admissionWorkOrder` in every engine scenario
  (`EngineTest.hs:154`, `EngineHumanTest.hs:155`, `EngineRecoveryTest.hs:169`, `EngineRecoveryTwoTest.hs:138`,
  `EngineCandidateTest.hs:150`, `EngineImplementTest.hs:145`, `EngineOwnershipTest.hs:117`, `EnginePageTest.hs:226`,
  `EngineAttemptPageTest.hs:165`, `LiveAdapterTest.hs:141`, `ServeWorkerTest.hs:186`, `EngineHelperPathTest.hs:239`).
  Not pinned: `enablementAt`, `admissionAt`.
- `ChecksChoice`/`EffectiveRules`/`KindRules`/`QueueEntry`/`ProjectChecks.checksQueue`: `ProjectChecksTest.hs:102,
  187-198, 233, 252-288`. `ExpectProfile`: `GateCRemediationTest.hs:440-441`; `ExecutionTest.hs:301-329`.
- `OpenDecision` facts and `DecisionReceipt`: `DecisionsTest.hs:42-121`; `ActivityPageTest.hs:57-222`;
  `GateCRemediationTest.hs:126`. Not pinned: `unknownObservations`.
- `Command.WorkspaceState` (positional) and `Receipt`: unit `Application/CommandTest.hs:145, 151-153`.
- `Ledger.Receipt.receiptState`: `LedgerTest.hs:116, 159`. `NewWorkOrder`: `LedgerTest.hs:376-384, 132-140`;
  `RemediationTest.hs:629-637`; `ReconciliationTest.hs:752-760`; `LedgerTraceTest.hs:310-318`; positional
  `ConversationTest.hs:95`. `WorkOrderView.woBindingDigest`: `LedgerTest.hs:129`. `ScheduleReceipt`:
  `LedgerTest.hs:195-232`; `RemediationTest.hs:407`; `ReconciliationTest.hs:487`. `StoredObservation`:
  `LedgerTest.hs:265-277`, `ExecutorTest.hs:133-379`, `ReconciliationTest.hs:160-394`, `RemediationTest.hs:234`,
  `Web/LedgerPageTest.hs:143-155`. `StoredRecovery`: `ExecutorTest.hs:220, 278`; `RemediationReviewTest.hs:181`;
  `Web/LedgerPageTest.hs:156`. `StoredResolution`: `ReconciliationTest.hs:159-396`; `RemediationTest.hs:184, 265`;
  `RemediationReviewTest.hs:154, 168`; `RemediationFinalReviewTest.hs:111`; `Web/LedgerPageTest.hs:150`.
  Not pinned: `SubjectView.viewState`, `SchedulePreview`, `LedgerFacts`/`OrderFacts`.
- `LedgerView` lines and projection: unit `Web/LedgerPageTest.hs:134-163`. `LedgerFailure` constructors:
  `LedgerTraceTest.hs:250-252`.
- `Executor.executorOwner`: `ExecutorTest.hs:464`; `ReconciliationTest.hs:457`; `RemediationTest.hs:377`;
  `LedgerTraceTest.hs:221`; `RemediationReviewTest.hs:234`; `RemediationFinalReviewTest.hs:183`;
  `RemediationThirdReviewTest.hs:188`.
- `RepositoryRecord.repositoryRecordOwner`: `GateCRemediationRetainTest.hs:225`.
- Executor/Reconciler outcomes: `RemediationTest.hs:148-304`; `RemediationFinalReviewTest.hs:113-131`;
  `RemediationThirdReviewTest.hs:109-139`; `ReconciliationTest.hs:152-386`; `ExecutorTest.hs:127-400`;
  `RemediationReviewTest.hs:85-161`.

### 4.5 Effects
- `Workspace`/`View`: unit `Effects/ClaudeAdapterTest.hs:80, 116`; integration `EngineRecoveryTest.hs:678-683`.
- `Runner.runnerName`: `LiveAdapterTest.hs:208`. `ProviderConfig` (positional): `ClaudeAdapterTest.hs:36-72`;
  `LiveAdapterTest.hs:180`. `RunnerFailure`: `RolesTest.hs:198-199`; `LiveAdapterTest.hs:286`;
  `EngineRecoveryTwoTest.hs:358`. `HelperFailure`: `RunnerProtocolTest.hs:142-173`; `ClaudeAdapterTest.hs:108-110`;
  `HelperRunnerTest.hs:148-194`.
- `GitSupervisor.Basis.basisCommit`: `SnapshotBoundsTest.hs:139, 155`; `EngineRecoveryTwoTest.hs:417`.
  `CommitMeta.metaMessage`: `GitSupervisorTest.hs:123`.
- Scripted steps, `LookupAnswer`, `DestinationAnswer`: unit `Effects/ExecutorTest.hs:56-156`,
  `Effects/ReconcilerTest.hs:51-94`; integration `ExecutorTest.hs:242-319`, `LedgerTraceTest.hs:181-184`,
  `ReconciliationTest.hs:127-596`, `RemediationTest.hs:226, 489-513`, `RemediationReviewTest.hs:84-120`,
  `RemediationFinalReviewTest.hs:119`.

### 4.6 Web
- No Web record field is pinned (`formKey` in `ProjectsPageTest.hs:104, 151` is a test-local variable).

## 5. Recommended order of work

Each step leaves the frozen suites green; pinned fields keep their `Text` and gain a typed field beside them (the
`projectKey`/`viewKey` pattern) until the owner amends the tests in §4.

1. **Kernel vocabulary first** (no pins involved, unblocks every later step).
   - Add the B types that rows need, in the Kernel: B1 `EngineerName`, B2 `AbsolutePath`, B3 `TreePath`/
     `ProtectedPath`, B4 `TreeId`/`BlobId` (fold `GitBasis.isCommitId` into `mkCommitId`), B5 `WorkBranch`, B6
     `GitRemoteName`, B8 `LeaseOwner`, B9 argv types, B10, B11, B12, B13, B14, B15–B31 code sums, B34 bounded text.
   - Move down below Persistence: `IdempotencyKey`, `Actor`, `Outcome` (Application/Command), `ReceiptOutcome`
     (Application/Decisions), `DecisionChoice` (Web/DecisionPages → B18). Add `parseMessageKind`, a `RequestKind`
     row decoder, and a hex parser for the digest; decide one digest type (Kernel `ContentDigest` with
     `Foundation.Digest` producing it at the boundary, as `sha256Hasher` already does).
   - Type the unpinned Kernel fields: `Profile.bApprover`, `WorkUnitLifecycle.verifiedChecks`, `Effect.reasonText`
     (C, leave), `Roles.reviewReasons` (bounded), and the unpinned constructors (`EffectSpec`, `Halt*` in `HaltCode`,
     `RoleEnded*`, `WeakensUniversalInvariant`).
   - Unify the duplicated hex/name validators (§1.3 item 3).
2. **Persistence rows** (156 fields, none pinned but `Migration`): replace each `unboundedTextField` with `codeField`
   or a typed field per §3.3; decode multi-column facts with `O.marshallPartial` (subject `kind`+`state`, request
   `kind`+`choices`+`state`+`answer`, invocation `outcome`); stop discarding typed decoders (`Commands.rowDigestHex`,
   `CommandCenter.evidenceDigestHex` keep bytes); read `enabled_at`/`admitted_at` as `UTCTime`. Encoded list columns
   (`classes`, `path_classes`, `verifiers`, `other_remotes`, `choices`) keep their stored encoding, decoded once into
   typed lists. Compliance tests: round-trip every code and a corrupt value per column (as Increment C did).
3. **Application, unpinned records**: `EngineRecords` (54 fields; keep record bytes identical through
   `FC.boundedEnum`/`FC.validate`, oracle-tested against stored bodies), `EngineEvidence`, `Profiles.ResolveRequest`,
   `Conversation.RequestDetails`, `CommandCenter`, `Repositories`, `ProfileDocument.GateDocument`, `Ledger`
   internals (`SubjectView`, `SchedulePreview`, `LedgerFacts`), `ControlPane.FolderList`, `Activity.activityTime`,
   `Engine.recordStage/viewEngineer/viewFolder`, `Execution.enablementAt/admissionAt`.
4. **Application, pinned records**: add typed companions beside the pinned text (`StoredRequest`, `StoredMessage`,
   `ProjectView`, `TaskView`, `Enablement`, `Admission`, `TransactionView`, `DecisionReceipt`, `Ledger.Receipt`,
   `NewWorkOrder`, `Stored*` ledger records, `LedgerView` lines, `ChecksChoice`) so no code reads the text back;
   then submit the §4 list as the owner amendment.
5. **Effects**: decode role answers with `FC.boundedEnum` (`tExpect`, `fHint`, review verdict, the five kind tags) and
   `FC.validate` into B3/B9/B10/B11 where the Kernel's `checkAnswer` codes are unaffected (the decoded `Kernel.Roles`
   records stay `Text` while pinned); `GitSupervisor.Basis.basisTree`, `walkedPaths`; `HelperRunner.preparedName`;
   pinned `Workspace`/`View`/`ProviderConfig`/`RunnerFailure`/`HelperFailure` get typed internals.
6. **Foundation protocols**: their own types (`RunName`, `OpName`, `RunnerOutcomeCode`, `HelperReasonCode`,
   `FolderPath`, `Hostname`, `PgIdentifier`), applied to the unpinned raw-decode fields first
   (`SystemConfig.raw*` with `rawPassword` straight into `Secret`); pinned protocol records wait for the amendment.
7. **Web** (after the concurrent Increment E work lands): Json bodies built from typed values (`RequestId`,
   `RawToken`, `Outcome`, B32 sums); form records stay the raw pre-validation shape only if `Web/Validation` is the
   single place they are read.
