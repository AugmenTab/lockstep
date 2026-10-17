# P1.4 Contract — Typed durable operator command

- Contract ID: `C-P1.4@v1`
- Status: **FROZEN** (2026-10-17)
- Basis: `v2` at `3090763`. P1.1/P1.2 ACCEPTED by the human owner at `b3a3723`; P1.3
  `VERIFIED — awaiting human acceptance` at `d2f04ea` (`docs/gates/P1.3/acceptance.md`).
- Authority: `.local/plans/phase-01.md` §P1.4 and operating rule 4 (the writing agent specifies a
  bounded just-in-time Contract); the owner's continuation of 2026-10-17 ("Proceed sequentially
  through P1.3–P1.7. Do not request ceremonial approvals"). No open decision gate applies
  (DG-03…DG-13 block Phase 2+; DG-04's event/outbox protocol is not P1 work).
- Traces: FR-APP-04, FR-APP-05 ("all writes via typed command boundary"), NFR-01, NFR-02;
  Plan v0.2 P1.4 ("Repeated POST returns same accepted identity; stale command is rejected");
  Plan risk row "Two HTTP requests with same command identity".
- Writer: the single writing agent (manual; no v2 Supervisor).

## 1. Objective

One small, versioned, typed operator command whose CLI and HTTP forms call **the same
validated application operation**, with an expected revision, an idempotency identity and a
durable PostgreSQL receipt. The representative operation is non-agent and bounded: **rename
the workspace** (a single stored display name with a revision counter).

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Envelope (version 1).** `CommandEnvelope { envelopeVersion = 1, envelopeActor :: Actor, envelopeKey :: IdempotencyKey, envelopeExpected :: Revision, envelopeCommand :: OperatorCommand }`. `Actor = ActorCli \| ActorBrowserSession` (authority: CLI = the OS user who can read the 0600 `LOCKSTEP_CONFIG`; browser = a live P1.3 session with a valid CSRF token). `OperatorCommand = RenameWorkspace WorkspaceName` (one constructor now; P1.5 adds more). |
| E2 | **Validation (pure, before admission).** `WorkspaceName`: the text with leading/trailing whitespace removed, 1–80 characters, no control characters. `IdempotencyKey`: 16–64 characters of `[A-Za-z0-9_-]`. `Revision`: an integer ≥ 0. Invalid input is refused with a typed `CommandInvalid` reason and **nothing is stored**. |
| E3 | **Payload identity.** `payloadDigest = SHA-256("lockstep-command-v1\n" <> kind <> "\n" <> expected revision <> "\n" <> name)`. The actor is **not** part of it: one key names one operation whoever submits it. |
| E4 | **Pure decision (NFR-01).** `decide :: WorkspaceState -> Maybe PriorReceipt -> CommandEnvelope -> Decision` with `Decision = Replay PriorReceipt \| KeyConflict \| Apply Revision \| RefuseStale Revision`, in this order: a prior receipt with the same key and the same digest → `Replay`; with the same key and another digest → `KeyConflict`; expected = current revision → `Apply (current + 1)`; otherwise `RefuseStale current`. Total, no IO. |
| E5 | **Admission (NFR-02).** `submitCommand :: DatabaseRuntime -> CommandEnvelope -> IO (Either CommandRefusal Receipt)` runs **one transaction**: `SELECT … FROM lockstep_workspace FOR UPDATE` (serializes every command), read the receipt for the key, `decide`, then for `Apply` update the workspace and insert an `applied` receipt, for `RefuseStale` insert a `refused_stale` receipt, for `Replay` return the stored receipt unchanged, for `KeyConflict` write nothing. The effect and its receipt commit together or not at all. The transaction runs to completion independently of the HTTP connection; nothing in it reads or writes the socket. |
| E6 | **Receipt.** `Receipt { receiptId, receiptKey, receiptKind = "rename-workspace", receiptOutcome = Applied \| RefusedStale, receiptExpected, receiptRevision (the revision after an applied command, or the current revision for a stale one), receiptActor, receiptAcceptedAt, receiptReplayed :: Bool }`. `receiptReplayed` is computed per call (not stored): `True` when E4 returned `Replay`. Refusals: `CommandRefusal = CommandInvalid InvalidReason \| CommandKeyConflict \| CommandNotReady NotReadyReason`. A stale command is **not** a `CommandRefusal`: it is a durable `RefusedStale` receipt, so a retry with the same key returns the same refusal. |
| E7 | **Migration `0003`** (ADR-0002 backup gate applies): `lockstep_workspace(singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80), revision bigint NOT NULL CHECK (revision >= 0), updated_at timestamptz NOT NULL DEFAULT now())` seeded with `('Lockstep', 0)`; `lockstep_command_receipts(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, idempotency_key text NOT NULL UNIQUE, envelope_version integer NOT NULL, command_kind text NOT NULL, payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32), actor text NOT NULL, expected_revision bigint NOT NULL, outcome text NOT NULL CHECK (outcome IN ('applied', 'refused_stale')), resulting_revision bigint NOT NULL, accepted_at timestamptz NOT NULL DEFAULT now())`. |
| E8 | **CLI.** `lockstep workspace show` prints `name: <name>` and `revision: <n>`. `lockstep workspace rename --expected-revision N [--idempotency-key K] NAME` (one positional `NAME`; options in any order before or after it; `--opt=V` forms accepted; duplicates refused). Without `--idempotency-key` the CLI generates one (22 base64url characters from the CSPRNG). Output on stdout, one line: `receipt <id> <applied\|refused_stale> revision <n> key <k>`, plus ` (replayed)` when replayed. Exit: applied 0; refused_stale 65 (receipt line on stdout, reason on stderr); key conflict 65 (stderr only); invalid 65 (stderr only); not configured 66; not ready 69; usage 64. Both need readiness `Ready` (else 69). |
| E9 | **HTTP.** `GET /operator` (protected, P1.3) also shows the workspace name and revision and a rename form with hidden `expected_revision`, `idempotency_key` (fresh per render, 22 base64url characters) and `csrf`. `POST /operator/commands/rename-workspace` (protected; Host/Origin/session/CSRF exactly as P1.3 E7) with form fields `name`, `expected_revision`, `idempotency_key`, `csrf`: applied (new or replayed) → `303`, `Location: /operator/receipts/<id>`; refused_stale (new or replayed) → `409` page showing the receipt id and the current revision; key conflict → `409` page, no receipt; invalid → `400`; database missing/not ready → `503`. `GET /operator/receipts/<id>` (protected) → `200` page with id, kind, outcome, expected and resulting revision, actor, acceptance time and key; unknown or malformed id → `404`. All `/operator*` headers as P1.3 E8 (`no-store`, `no-referrer`). |
| E10 | **One operation.** `Lockstep.Application.Command` holds validation, the envelope, `decide` and `submitCommand`. `Main` and `Lockstep.Web.Operator` only parse input into an envelope and render the result. |
| E11 | **Layering.** `Lockstep.Application.Command` (uses `Lockstep.Persistence.Commands`), Web and CLI as above. No Henforcer config change. No new dependency. |

## 3. Allowed paths

`src/Lockstep/{Foundation,Persistence,Application,Web}/**`, `app/lockstep/Main.hs`,
`test/unit/**` and `test/integration/**` (**new files only**, plus the runner additions in §8),
`package.yaml`, `lockstep.cabal`, `README.md`, `docs/gates/P1.4/**`.
Not allowed without a stop: any frozen P1.1/P1.2/P1.3 test, fixture or script; Henforcer
configs; `.hlint.yaml`; `scripts/lib/check-forbidden-facilities`; `stack.yaml*`; `Dockerfile`.
Out of scope: background execution and queues (P1.5), the command-center view (P1.6).

## 4. Production API the tests bind to

```haskell
-- Lockstep.Application.Command
data Actor = ActorCli | ActorBrowserSession
data WorkspaceName; mkWorkspaceName :: Text -> Either InvalidReason WorkspaceName; workspaceNameText :: WorkspaceName -> Text
data IdempotencyKey; mkIdempotencyKey :: Text -> Either InvalidReason IdempotencyKey; idempotencyKeyText :: IdempotencyKey -> Text
generateIdempotencyKey :: IO IdempotencyKey
newtype Revision = Revision Int64
data InvalidReason = NameEmpty | NameTooLong | NameHasControl | KeyMalformed | RevisionNegative
data OperatorCommand = RenameWorkspace WorkspaceName
data CommandEnvelope = CommandEnvelope { envelopeVersion :: Int, envelopeActor :: Actor, envelopeKey :: IdempotencyKey, envelopeExpected :: Revision, envelopeCommand :: OperatorCommand }
mkEnvelope :: Actor -> IdempotencyKey -> Revision -> OperatorCommand -> CommandEnvelope   -- version 1
payloadDigest :: CommandEnvelope -> ByteString
data WorkspaceState = WorkspaceState { workspaceName :: Text, workspaceRevision :: Revision }
data PriorReceipt = PriorReceipt { priorDigest :: ByteString, priorReceipt :: Receipt }
data Outcome = Applied | RefusedStale
data Receipt = Receipt { receiptId :: Int64, receiptKey :: Text, receiptKind :: Text, receiptOutcome :: Outcome, receiptExpected :: Revision, receiptRevision :: Revision, receiptActor :: Actor, receiptAcceptedAt :: UTCTime, receiptReplayed :: Bool }
data Decision = Replay Receipt | KeyConflict | Apply Revision | RefuseStale Revision
decide :: WorkspaceState -> Maybe PriorReceipt -> CommandEnvelope -> Decision
data CommandRefusal = CommandInvalid InvalidReason | CommandKeyConflict | CommandNotReady NotReadyReason
submitCommand :: DatabaseRuntime -> CommandEnvelope -> IO (Either CommandRefusal Receipt)
readWorkspace :: DatabaseRuntime -> IO (Either NotReadyReason WorkspaceState)

-- Lockstep.Foundation.Cli (additions)
Command: ... | WorkspaceShow | WorkspaceRename RenameArgs
data RenameArgs = RenameArgs { renameExpected :: Integer, renameKey :: Maybe String, renameName :: String }
```

## 5. Tests (frozen before implementation; §8)

Unit (`lockstep-unit`, no network):

| Area | Cases |
|---|---|
| Validation | name trimmed; empty / whitespace-only → `NameEmpty`; 80 ok, 81 → `NameTooLong` (characters, not bytes); tab/newline/DEL → `NameHasControl`; key 16 and 64 ok, 15/65/`+`/space/empty → `KeyMalformed`; generated key valid, 22 chars, two differ |
| Digest | equal for equal payloads whatever the actor; differs by name, by expected revision; 32 bytes; known vector |
| Decide | each of the four outcomes; replay wins over a stale revision; conflict wins over apply; apply returns current + 1 |
| CLI | `workspace show`; `workspace rename` with `--expected-revision N NAME`, `=` forms, option after the name, `--idempotency-key`; missing expected revision → `MissingOption "--expected-revision"`; non-numeric → `InvalidRevision`; missing name → `MissingArgument "NAME"`; two names → `UnexpectedArgument`; duplicate option → `DuplicateOption`; `workspace` alone → `MissingSubcommand`; unknown → `UnknownCommand`; earlier commands unchanged |
| App (no database) | `POST /operator/commands/rename-workspace` without a session → 401, with a missing Origin → 403; `GET /operator/receipts/1` without a session → 401; `GET /operator/commands/rename-workspace` → 404 |

Integration (`lockstep-integration`, real PostgreSQL 17.11 and the real binary):

| Case | Asserts |
|---|---|
| CLI happy path | fresh migrate → `workspace show` = `Lockstep` / 0; rename → `applied revision 1`; show = new name / 1 |
| CLI replay | same key + same payload → identical receipt line plus ` (replayed)`; one receipt row; revision 1 |
| Key conflict | same key, other name → exit 65, nothing changes, still one receipt |
| Stale | new key, expected 0 when current is 1 → exit 65, `refused_stale revision 1`; state unchanged; retry with that key → same receipt id, replayed |
| Invalid | empty name, 81 characters, a malformed key → exit 65, no receipt row |
| HTTP happy path + replay | sign in; `/operator` shows name, revision, a form with `expected_revision` and a 22-char key; POST → 303 to `/operator/receipts/<id>`; receipt page shows `applied`; the same POST again → 303 to the same location; one receipt row |
| CLI and HTTP share the operation | a CLI rename with key K, then an HTTP POST with key K and the same payload → 303 to the CLI's receipt; an HTTP POST with key K and another name → 409, no change |
| HTTP stale / conflict / invalid | stale → 409 with the receipt id; conflict → 409; empty name → 400; none changes state |
| HTTP authority | no session → 401; wrong CSRF → 403; foreign Origin → 403; none stores a receipt |
| Concurrency | two concurrent POSTs with one key → both 303 to the same receipt, one row; two concurrent different keys at the same expected revision → one applied, one refused_stale, revision + 1 |
| Disconnect | a raw POST whose client closes the socket right after sending → the receipt appears (polled ≤ 5 s) and the revision advanced |
| Backup gate | a database at revision 2 → `db migrate` without a flag → exit 75; `--no-backup` → applies `0003` |

## 6. Verification

Pre-freeze: candidate tests compile against type-only stubs under `--pedantic` and the unchanged
Henforcer configs; fourmolu and the lint step clean; baseline against `3090763` fails only on
missing modules/exports. Acceptance: fresh clone and Linux clone `scripts/check --integration`;
frozen digests for P1.1–P1.4; runner diffs additive; `scripts/licenses` unchanged; an operator
run (CLI + curl) against the operator database with a backup before `0003`.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test; frozen tests never edited. Stop on a
behaviour that makes a frozen expectation impossible, a path outside §3, a new dependency, or a
design question §2 does not settle. Rollback: revert the P1.4 commits; `0003` on the operator
database is handled by restoring the pre-migration backup (ADR-0002).

## 8. Freeze record

Frozen 2026-10-17 by the writing agent (manual; no v2 Supervisor). Frozen test files never
change in P1.4.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Application/CommandTest.hs` | `78912e3aaffc98ad739276645f6699c94fb9cb2334dbff7a3d5e1715bec6cf13` |
| `test/unit/Lockstep/Foundation/CliWorkspaceTest.hs` | `e18a4b87ea53b1989d4ab8dbb802c935fe301240653bbc888a3072ea04f5fba0` |
| `test/unit/Lockstep/Web/CommandRoutesTest.hs` | `e9deceb6bea6d0bec83c483eb46963d65cbea218a7dd48e0773b46009574ee26` |
| `test/integration/Lockstep/OperatorCommandTest.hs` | `df09352b9ce831279e25cab7d502d434e803e09e3c223738bac53f6cce7950b7` |
| `test/unit/Main.hs` (runner, additive) | `6105187d6411c71e868c2d1301f5c5dcdc264ecae4477ba3247ba1cda43b9a63` |
| `test/integration/Main.hs` (runner, additive) | `71515029e73aaf9b325da5975650af080e33ef3b0a57e4d3faa045b331b5021f` |

Runner changes (named in advance, additive only): `test/unit/Main.hs` gains `CommandTest`,
`CliWorkspaceTest`, `CommandRoutesTest` (6 added lines); `test/integration/Main.hs` gains
`OperatorCommandTest` (2 added lines). Frozen helpers `Support/{Process,Postgres,Http}.hs` reused
unchanged. No Henforcer or forbidden-facility change.

Pre-freeze verification (§6): type-only stubs (scratch, not committed:
`Lockstep.Application.Command`, the `Cli` additions) — both suites compile under `--pedantic`
and the unchanged Henforcer configs (`evidence/prefreeze-stub-build.log`); fourmolu and lint
clean; baseline against `3090763` fails only on the missing module `Lockstep.Application.Command`
and the missing `RenameArgs` export (`evidence/prefreeze-baseline.log`). Frozen P1.3 tests that
touch the migration list were checked against `0003`: the backup-gate test expects
`applied migrations: 2` as a substring, which `applied migrations: 2, 3` still satisfies.
