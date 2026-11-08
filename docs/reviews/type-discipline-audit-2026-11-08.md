# Type-discipline audit — 2026-11-08

## Scope and method

- **Code:** all of `src/` (130 modules, about 32,600 lines), plus `static/app.js` and `static/control.js`.
- **Standard:** `docs/architecture/STACK_PATTERNS.md`, a study of how Launchpad and Artificer use the stack.
- **Reading:** every module was read in full by five reviewers, one per layer group:
  - Kernel;
  - Application (two halves);
  - Persistence with Foundation;
  - Web with Effects.

  Each reviewer cited file:line for every finding.
- **Checks:** the central claims were then verified directly. Verified claims are marked ✔. Grep confirmed that `convertField`, `tryConvertSqlType`, `fleeceField`, `O.uuidField` and `Orville.PostgreSQL.Plan` appear **nowhere** in `src/`.

## The answer in one paragraph

The Kernel models the domain properly. Lifecycles are ADTs that carry their evidence, refusals are mostly typed, and nothing is partial. **Every boundary then throws that away.** Identifiers become `Text` as soon as they leave the Kernel. Persistence rows are all `Text`/`Int32`/`Maybe`, and the Application decodes them by hand, often with defaults. States, kinds, outcomes, verdicts and refusal codes travel as strings, and decisions are taken by string comparison, prefix search and substring search. The web layer is three hand-written routers over `pathInfo`. Its links are string literals, its forms are parsed by hand with string field names, and the browser holds a second copy of the route table. The libraries are present but used as syntax: Orville tables whose columns are all text, Brigid elements with raw-string URLs and `customAttribute`, and Fleece schemas whose enum fields are `FC.text`. The type system is doing almost none of the work it was chosen to do.

---

## 1. Domain types and identity

**Verdict: identifiers are not types.**

There are seven Kernel ID newtypes, over a hand-written `Uuid`. Outside the Kernel almost every ID is `Text`. Validation of an ID routinely parses the value and then throws the result away. Different entities can be confused in nearly every signature.

| Finding | Evidence |
|---|---|
| Hand-written UUID type, parser, printer and byte decoder ✔ | `Kernel/Identity.hs:30-120` |
| Hand-set v4 bits, with a nil-UUID fallback ✔ | `Application/Identity.hs:19-35` (`fromRight (uuidFromWords 0 0) …`) |
| The `uuid` column type is carried as `Text`; every key and FK is built from it ✔ | `Persistence/Fields.hs:78-84` |
| Every keyed table is `TableDefinition (HasKey T.Text) …`, so `findEntity ticketTable workOrderId` compiles | Persistence: Ledger, Transactions, Conversation, Projects, Tasks, Repositories, Sandbox |
| FKs re-declared as fresh `uuidField "…_id"`, never derived from the referenced table | `Persistence/Ledger.hs:339,341,913-916`, `Transactions.hs:158`, `Execution.hs:178` |
| Validate-then-discard: `canonicalId = … uuidText . parseUuid`, `validId = either (const False) (const True) . parseUuid` | `Application/Engine.hs:211` (copied into Execution, Tasks, Conversation, Projects), `Web/App.hs:140-142` |
| One URL carries two entity kinds; the posted `choice` string decides whether the segment is a `WorkOrderId` or an `OperationId` ✔ | `Web/App.hs:518-526`; links at `Web/ActivityPage.hs:77,90` |
| Adjacent, swappable `Text` IDs in public signatures | `Persistence/Ledger.hs:919` (5 IDs), `Projects.hs:149`, `Application/Projects.hs:310` (4 × `Maybe Text`), `Application/Tasks.hs:253` (actor + task), `Repositories.hs:240` |
| `ProjectId`, `TaskId`, `TransactionId`, `InvocationId`, `HumanRequestId`, `JobId`, `ReceiptId`, `ProfileId` have no type at all | throughout |
| Engineers identified by name in some tables and by UUID in others; `engineer_name` has no FK | `Persistence/Transactions.hs:182`, `Execution.hs:103`, `Projects.hs:96` vs `Repositories.hs:122` |
| Unvalidated ID text reaches a stored digest: `fromMaybe rawId (canonicalId rawId)` | `Application/Execution.hs:408`, `Tasks.hs:169` |
| Commits, trees, blobs and branches are all `Text`; `isCommitId` is re-checked at every entry | `Effects/GitSupervisor.hs:169-173, 199-609` |
| Digests have two representations (bytea `ByteString`, hex `Text`) and neither is a type | Persistence Commands, Jobs, Ledger, Transactions |
| Hand-formatted IDs: UUID formatted by hand, plus random-hex names | `Effects/Provider/Claude.hs:141-143`, `HelperRunner.hs:279`, `Roles.hs:155` |
| Validated text kept as `Text`: titles, acceptance text, paths, names, owners; the kebab-name rule written 5× | `Kernel/Task.hs:73`, `GitBasis.hs:72`, `Effect.hs:93`, `Profile.hs:158`, `Scheduler.hs:87`, `Ledger.hs:333-502` |

**Done well:**
- The Kernel smart-constructed types: `CommitId`, `ContentDigest`, `ProfileId`, `GateId`, `EffectKey`, `ProjectName`, `TaskTitle`.
- `WorkspaceName` and `IdempotencyKey`, with hidden constructors.
- `RawToken`, with constant-time `Eq` and a redacting `Show`.
- The ledger and activity pages carry Kernel IDs.

## 2. State and invariants

**Verdict: the ADTs exist but do not survive the boundary.**

States are stored as text plus loose `Maybe` columns. The Application rebuilds them from tuples. Decision logic outside the Kernel matches strings, often with catch-alls.

**Decisions made on string content:**
- "Human-attested" is a text prefix written into a reason and read back with `isPrefixOf` ✔ (`Kernel/Reconciliation.hs:132`, `Activation.hs:101`, `EffectView.hs:92`). A destination reason that happens to begin with that text is shown as attested.
- Task state is `Text`, matched against string literals, with `otherwise -> BeingWorkedOn` ✔ (`Kernel/Task.hs:143-180`; again at `Web/TaskPages.hs:151-166`). A misspelt state is shown as "being worked on".
- Invocation outcomes are a sum type packed into one string. They are recovered with `stripPrefix "uncertain "`, and "executable missing" is detected with `isInfixOf` over refusal codes ✔ (`Application/Engine.hs:840-853, 1078`; `EngineEvidence.hs:149`).
- Effect-key safety (duplication risk) is decided by comparing state names and `"human-abandon"` strings (`Application/Ledger.hs:1540-1544`).
- The review verdict is compared with `== "approve"`, although `Verdict` exists and `Roles` decodes it (`Engine.hs:1601`, `EngineRecords.hs:409`).

**Text in place of enums:**
- Transaction state, stage and halt code are text. Halt codes carry parameters by concatenation (`"role-failed " <> code`) and are taken apart by prefix (`Kernel/Transaction.hs:125-334`, `Web/ExecutionPages.hs:164-343`).
- Subject kind, resolution basis, profile layer level, receipt outcome, job state, decision operation and decision outcome are all string literals (Ledger, CommandCenter, Profiles, ProjectChecks, Execution).
- Every Fleece record field that holds an enum (stage, verdict, disposition, mutant run, expectation, run outcome) is `FC.text` (`EngineRecords.hs:96-422`).
- `TaskState`, `TxState`, `Verdict` and `Disposition` reach the pages as text and are matched with `_ ->` fallbacks.

**Row shapes the ADT forbids:**
- `IntentRow` has 24 fields, including a text state, loose lease/outcome `Maybe`s and `Maybe Bool`. There are nine legal combinations and the rest are rejected by hand in `restoreIntent` (`Persistence/Ledger.hs:437-463`, `Application/Ledger.hs:1209-1270`).
- `TransactionRow`: a stage-dependent set of `Maybe Text` commit columns, re-checked at every stage (`Engine.hs:757-1617`).
- `ProjectRow`, `RequestRow`, `InvocationRow` and the decision rows have the same pattern.

**Ad hoc encodings:**
- Comma-joined lists in text columns: classes, path classes, verifiers, remotes, choices.
- `show device <> ":" <> show inode` read back with `readMaybe` (`Repositories.hs:271-312`).
- A carry decision built as a `show`-formatted string (`Ledger.hs:1997`).
- A ledger basis `"order:" <> show n` compared for equality (`Decisions.hs:180-194`).

**Bool flags and bare `Int`s for distinct concepts:**
- Revisions, generations, activations and attempt numbers are all mutually assignable.
- `MutantSurvived Bool`, `RetryAcknowledgingDuplication Bool` (where `False` is always refused) and `abandonIntentAcknowledged … Bool`.
- The tri-state `Maybe Bool` for inherit/permit/forbid.

**Sentinels:**
- A `"none"` profile and an `expected_set=yes|no` hidden-field pair (`Web/App.hs:399-404`).
- `ExitFailure (-1)` meaning "unknown exit" (`Effects/Process.hs:171,207`).

**Done well:**
- Kernel lifecycles: `TicketState`, `WorkOrderState`, `WorkUnitState`, `DeliveryState` and `IntentState`, with their evidence.
- `ClassTerms`, `RequestKind`, `Behaviour`, `RunOutcome`, `HelperFailure` and `Section`.
- The readiness and migration error types.

## 3. Layer boundaries

**Verdict: database and wire representations leak through the whole application.**

Orville translates text to text. The Application does the decoding. Pages get bytes, and the browser owns state.

**Persistence exposes database-shaped records:**
- Persistence returns them, and the Application decodes them in about 150 lines of hand-written code (`replayWorkOrder`, `loadBinding`, `restoreIntent`, `storedEvidence`; `Application/Ledger.hs:664-916, 1235-1288`).
- `uuidOf` re-parses stored IDs at about ten read sites.
- The engine's stage functions take and return `Store.TransactionRow`; the persistence row is the working type (`Engine.hs:394-1617`).

**Display formatting and domain meaning in Persistence:**
- Timestamps are returned as formatted `Text` (`Persistence/Execution.hs:69-71`).
- Digests are returned as hex `Text` while their write type is bytes (`Commands.hs:109`, `CommandCenter.hs:119`).
- A domain state is branched on: `intentRowState row == "dispatched"` (`Ledger.hs:656`).

**JSON as text:**
- Role context documents are hand-built `Foundation.Json` values that splice stored JSON with `JRaw (fromMaybe "null" …)` ✔ (`Engine.hs:1104-1557`).
- Records are stored as text and re-decoded at every stage, and a decode error becomes `Nothing` and then `"candidate-missing"` (`EngineCandidate.hs:51-55`).
- Two JSON encoders are kept byte-identical by hand (`Foundation/Fleece.hs:23-26`).

**Line protocols:**
- Every protocol (control, folder, install, lifecycle, session, runner) has an encoder and decoder written separately, and the encoders do not enforce what the decoders require. `decodeRunnerResult` re-implements `decodeResult` with weaker checks (`Foundation/*Protocol.hs`).

**Web:**
- Handlers move `[(ByteString, ByteString)]`, `Text` and `LBS.ByteString` around.
- Page functions return rendered bytes, so no response type records where a fragment goes (`Web/Fragment.hs:26`).
- One page response makes seven independent Application calls, each failure folded to "nothing" with `fromRight` (`Web/App.hs:614-644`).
- Environment variables are read inside request handlers (`Web/App.hs:275…988`).

**The browser owns routing and state:**
- `static/app.js` has its own route table, section list and POST-route regex. It rewires every form and link through `htmx.ajax`, and the server tells it what URL to push with a custom header (`app.js:11-56, 99-203`; `Web/App.hs:587-713`).
- `static/control.js` (662 lines) holds the control pane's state machine, its labels, its enablement rules and a copy of the folder-path rule. The server sends a map of dotted string keys for it to interpret.

**Done well:**
- `Application.Database`'s typed facade.
- `LedgerView.OrderLine` keeps the Kernel types.
- `Effects/Process` keeps OS detail behind a typed `RunSpec`/`RunResult`.

## 4. Totality and failure handling

**Verdict: total but lossy.**

There is no `head`, `fromJust`, `!!`, `read`, `error` or `undefined` in the tree. But failure is almost everywhere `Either Text`. Typed refusals are flattened to code strings and `show` text. Dummy defaults and swallowed results hide failures, and some of these are real defects.

**Defects to fix regardless of the larger work:**
1. **The Profile digest is computed with `show` and falls back to 64 zeros** ✔ (`Application/Profiles.hs:73-80`). If the `Show` format ever changed, every profile would silently share one digest.
2. **Revision overflow passes validation** ✔ (`Application/Command.hs:199`). `if expected < 0 … else Revision (fromInteger expected)` wraps an `Integer` above `maxBound :: Int64` to a negative revision *after* the negativity check.
3. **The migration checksum depends on crypton's `Show Digest`** ✔ (`Persistence/Migration.hs:69-72`). Applied migrations are immutable and checked by this value, so it must not rest on a debugging format. The value should not change when this is fixed: `convertToBase Base16` gives the same lowercase hex. This must be proven with a test before switching.
4. **Unchecked text is stored when its check fails**: `body = fromRight (inputText input) (checkRequestText …)` (`Application/Conversation.hs:324`). Validated text is also thrown away and the raw input hashed (`Kernel/Conversation.hs:200`, `Decision.hs:91`).
5. **Dummy event text**: `createCommand = fromRight "create" …` (`Application/Ledger.hs:637-639`). A failure would write a creation event that later replays as an integrity error.
6. **Empty-string digest stored**: `admissionRowEffectiveDigest = fromMaybe T.empty effective` (`Application/Execution.hs:482`).
7. **A corrupt row reads as a valid default**: `fromMaybe Organized (parseSetupState …)` (`Application/Projects.hs:124`), and `lastStage` defaults to `StageBasis` (`Engine.hs:236`).
8. **The PostgreSQL error is dropped when a migration fails** (`Persistence/Migrate.hs:122-125`).
9. **Unchecked narrowing**: `int32 = fromIntegral`, used about 30 times on caller-supplied values (`Application/Ledger.hs:327`), plus `Tasks.hs:165`, `Profiles.hs:176,195` and `Ledger.hs:1163`.

**Systemic issues:**
- **Refusals as `Text`:**
  - `LedgerFailure = LedgerRefused Text Text` carries about 40 code literals and `show`-rendered messages (`Application/Ledger.hs:205`).
  - Kernel `Either T.Text` refusals in Transaction, Conversation, Roles, Runner, GitBasis and Decision.
  - Callers match codes with `==` (`Execution.hs:467`, `Tasks.hs:269`, `Projects.hs:349-368`, `Web/App.hs:419`).
- **Text-keyed word tables with catch-alls:** a new code silently gets the generic sentence (`Kernel/Activity.hs:72`, `Decision.hs:127,146`, `Policy.hs:247`, `Project.hs:257`, `Task.hs:273`, `Execution.hs:182`, and the `Web/*` words functions).
- **Swallowed results:** `_ <- finishInvocation`, `fromRight [] pending`, `() <$ ensureRequest`, `haltForIntentBy … _ -> pure ()`, and `Warp.setOnException (\_ _ -> pure ())` (`Engine.hs:515-1038`, `EngineWorker.hs:57-76`, `Ledger.hs:1578`, `Web/Control.hs:87`).
- **Stringly exceptions:** `throwIO (userError …)` used for control flow inside Orville code (`Persistence/Ledger.hs:633,936`, `Application/Profiles.hs:127`, `Command.hs:395`, `Repositories.hs:116,220`, `Sandbox.hs:83-105`).
- **`show` as a stored or wire format:** the principal is stored two different ways (`T.toLower (show p)` vs `show p`; `Engine.hs:384`, `Conversation.hs:266,336`), and `show` appears inside hashed canonical forms and idempotency keys.
- **The HTTP status does not reflect the outcome:** form validation failures return 200, and other statuses are chosen by hand in each handler (`Web/App.hs:272-546`).

## 5. Library integration

**Verdict: present, but used as syntax.** In nearly every case the libraries replace low-level syntax and do not carry types.

| Library | How it should carry types (STACK_PATTERNS) | What Lockstep does |
|---|---|---|
| **uuid / uuid-types** | `Data.UUID` behind every ID newtype; `nextRandom` | Not a dependency. A hand-written `Uuid`, hand-set v4 bits and hand-formatted UUIDs |
| **Orville** | `Entity`/`EntityKey`; typed key and FK fields; `convertField`/`tryConvertSqlType`; `uuidField`; `fleeceField`; `Plan` | None of them. All-text columns, re-declared FKs, string-literal state filters, `ConflictOn "name"`, `LOCK TABLE` with literal table names, and per-row loops in place of `Plan` (`Application/Ledger.hs:1887-1903`) |
| **Fleece** | One schema per payload, enums as `boundedEnum`, sums as `TaggedUnion`, JSON columns via `fleeceField` | The record schemas are real and two-way (good), but enum fields are `FC.text`. Role answers are dispatched by decoding `kind` as text first (`Effects/Roles.hs:451-464`). Role contexts still go through the hand-built `Foundation.Json` |
| **Beeline / Orb / Shrubbery** | Every endpoint is a route type; paths are values used both ways; typed params; declared bodies, responses and permissions | Only health, readiness and liveness. `/app` (29 routes), `/operator` (10) and the control pane (15) are `case` expressions over `pathInfo` (`Web/App.hs:144-180`, `Operator.hs:85-98`, `Control.hs:125-166`). The static path is defined twice |
| **Brigid** | Typed URLs (`B.get`), `A.htmx`, `A.hxTarget`, `B.Id`/`B.Name` shared with validators | About 60 internal URL string literals via `B.mkRawURL`. Ids, names and `for` attributes through `customAttribute` with two hand-written escapers. A byte-level rewrite of rendered entities (`Web/Fragment.hs:33-51`). No `A.htmx` anywhere |
| **Validation (Launchpad)** | An applicative `Validator` keyed by `B.Name`, giving a 422 | Absent. `parseSimpleQuery` plus `L.lookup "name"`, lenient UTF-8, and duplicates handled differently on `/app` and `/operator` |
| **cookie** | `renderSetCookie defaultSetCookie {…}` | `Set-Cookie` built by string concatenation (`Web/Operator.hs:261-271`), while the same module uses `parseCookies` |
| **bounded-text** | Length-bounded validated text | Dropped from the dependencies; about seven hand-written `1..N` checks |
| **optparse-applicative** | — (not in Launchpad, but the standard library for this) | A 919-line hand-written CLI with seven option loops that behave inconsistently and a hand-maintained usage string (`Foundation/Cli.hs`) |
| **text / containers / base** | `Data.Text.Read.decimal`, `nubOrd`, `Map`, `listToMaybe`, `unsnoc` | About seven hand-written digit folds, O(n²) `nub` duplicate checks in about 12 places, association lists checked for duplicates at runtime, and re-implemented `listToMaybe`/`findM`/`lastMay` |
| **crypton / memory** | One digest type, hex via `convertToBase` | Three SHA-256 hex implementations (one via `show`), `sha256Text` copied five times, and five copies of the hex predicate |

**Done well:**
- `Web/Health`, `Readiness` and `Liveness` follow the pattern exactly.
- `SystemConfig` decodes through Fleece and refuses unknown keys.
- The Orville expression layer is used properly for the job claim, joins, synthetic counts and `insertIgnoringConflict`.
- `O.withTransaction` is used everywhere.

## Root causes

1. **The type ends at the Kernel's edge.** Every boundary converts typed values to `Text` "for now", and nothing converts them back. Because the conversion lives in each caller instead of in a field, schema or param, it is repeated, inconsistent and defaulted.
2. **The adopted Launchpad pieces were never built.** ADR-0001 retained `Database.Entity`, `Validation`, permission actions and Orb dispatch. None of them is in `src/`, so every feature reinvented its own version.
3. **Stringly protocols became the internal model.** Canonical text forms written for hashing and evidence are also used as the in-memory representation and the decision input.

## Remediation order

Each step unblocks the next. The frozen tests, the stored bytes and the digests constrain how each step is done, but they do not stop any of them.

1. **Defects first** (§4 items 1–9). These are small, local and test-backed, and none of them needs the redesign.
2. **Identity:**
   - add `uuid-types` and `uuid`;
   - put Kernel IDs over `Data.UUID`, keeping the frozen canonical-lowercase rule as a check on `fromText`;
   - add the missing ID newtypes;
   - give each ID its field, param and schema;
   - adapt `Entity`/`EntityKey`/`mkEntityTable` to UUID keys, with FKs derived from tables.
3. **Typed fields:**
   - give each Kernel ADT its `toText`/`fromText`, `convertField`, `boundedEnum` and Beeline param;
   - read rows directly as ADTs, so an invalid combination fails in the marshaller;
   - store lists and documents through `fleeceField`;
   - make records and role answers `TaggedUnion`s;
   - replace `Foundation.Json`.
4. **Typed failures:** a refusal ADT per module and in `LedgerFailure`; word tables become exhaustive `case` expressions; no `show` in stored or hashed forms.
5. **Web:**
   - one Orb route tree for `/app`, `/operator` and the control pane;
   - typed path params, links and `A.htmx`;
   - `FormDataRequestBody` + `Validator` and `SchemaRequestBody`;
   - permission actions for sessions;
   - server-rendered pages, retiring the client route table and the control-pane state machine in JS.
6. **Libraries:**
   - optparse-applicative for the CLI;
   - bounded-text;
   - `Plan` for the per-row loops;
   - shared digest and hex helpers;
   - `Data.Text.Read`/`containers` in place of the hand-written folds and `nub`s.

## Not verified here

- Whether Orville 1.1.1 has a `bytea` `SqlType`. `Fields.hs` says it does not; this has not yet been checked in ghci.
- Which frozen tests pin the CLI's error wording, the `Fragment.namedEntities` rewrite and the canonical line formats (`EventCodec`, the protocol lines). Those pins decide whether each change keeps the current bytes or needs an owner-approved test amendment.
