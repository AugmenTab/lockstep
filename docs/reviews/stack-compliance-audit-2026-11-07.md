# Technology-stack compliance audit — 2026-11-07

- Handoff: `phase-04_update9` (owner-approved post-Phase-4 remediation). Branch `remediation/stack-compliance`,
  from `main` `e1c0770` (the accepted Haskell V2 tree).
- Scope: the Haskell V2 application against its approved stack (Project Bible v2.2, PRD v0.3, ADR-0001): Orville
  for PostgreSQL, json-fleece for JSON, Orb/Beeline/Shrubbery for HTTP, Brigid for HTML, HTMX and minimal JS.
- Reference: Launchpad `11886bf` (`.local/launchpad-main.zip`, BSD-3-Clause, same author; `LICENSE-LAUNCHPAD`
  already in the tree). Patterns used: `Database/Entity.hs` and `Database/Schema/*` (one table definition per
  table, explicit marshallers, typed `where_`/`fieldEquals`, `updateFieldsAndReturnRowCount`, `O.withTransaction`),
  `Util/Orville/Fleece.hs` (custom field types beside the persistence layer), `Data/User/UserSettings.hs` and
  `Data/Theme.hs` (one canonical `FC.Schema` per payload, explicit enum text). No Launchpad business code was
  copied.
- Library versions verified in the dev container with ghci (`stack exec ghci`): orville-postgresql 1.1.1.0.0,
  json-fleece-core 0.10.0.0, json-fleece-aeson 0.5.0.0 (`stack.yaml.lock`).
- Classes: **Required** (clear stack violation or substantial avoidable type-safety deficiency), **Recommended**
  (consistent with the stack, not needed for compliance), **Acceptable exception** (deliberate lower-level code
  with a stated reason).
- Prior record: `docs/reviews/fleece-audit-2026-10-28.md` (J1–J4) and the 2026-10-28 Orville survey, both deferred
  by the owner to this pass.

## 1. Persistence (Orville)

Before this pass every module in `src/Lockstep/Persistence/` used Orville only as a string executor: SQL text
built with `RawSql.fromString`, values spliced as parameters, `CAST(... AS uuid)` and `decode(..., 'hex')` written
by hand, every column name repeated as a string in the statement and again in an ad hoc marshaller, `id::text`
casts in every select. There were no `TableDefinition`s, no `insertEntity`, no `findEntitiesBy`, no typed `where_`.

| # | Module | Finding | Class | Correction |
|---|---|---|---|---|
| O1 | all 17 data modules | Routine CRUD (select by key, insert, conditional update, ordered lists) as SQL strings | Required | One `O.TableDefinition` per table with an explicit marshaller over typed fields; `findFirstEntityBy`/`findEntitiesBy` with `where_`/`orderBy`, `insertEntity`/`insertAndReturnEntities`, `updateFields`/`updateFieldsAndReturnEntities`. Public functions keep their names and types, so the Application layer is unchanged. |
| O2 | all | Column names repeated as strings in statements, marshallers and conditions | Required | Each column is one `FieldDefinition`; statements, conditions, ordering and marshallers all use it. |
| O3 | all | `uuid` columns read as `id::text` and written as `CAST($1 AS uuid)` by hand | Required | `Fields.uuidField`: a `uuid` column carried as its canonical text (same values in and out; malformed text is still refused by the server). |
| O4 | OperatorSessions, Commands, Repositories, Jobs, CommandCenter | `bytea` digests written as `decode($1,'hex')`, read as `encode(...,'hex')` | Required | `Fields.digestField`: a typed `bytea` field (Orville 1.1 has none) over PostgreSQL's `\x` hex text format. |
| O5 | Ledger, Repositories, Profiles, Tasks, CommandCenter, Transactions | Joins as SQL strings with table aliases | Required | Typed joins: `Expr.join`/`joinOnConstraint` over qualified fields, selected through the marshaller's own columns (`Fields.selectJoined`). |
| O6 | Ledger, Conversation, Commands, Transactions | `FOR UPDATE`, `FOR UPDATE OF`, `FOR UPDATE SKIP LOCKED` as text | Required | Orville's `forRowLock`/`rowLockingClause` (`Fields.forUpdate`, `forUpdateOf`, `forUpdateSkipLocked`). |
| O7 | Projects, Tasks, Transactions | Optimistic concurrency (`... AND revision = N RETURNING id`) as text, with the expected revision spliced with `show` | Required | `updateFieldsAndReturnEntities` with a typed `revision = expected` condition and a typed `revision = revision + 1` set clause (`Fields.increment`). Same single atomic statement. |
| O8 | Repositories, DecisionReceipts, Sandbox | `INSERT ... ON CONFLICT ... DO NOTHING RETURNING` as text | Required | Built from the table definition with Orville's `mkInsertExpr` and `onConflict` (`Fields.insertIgnoringConflict`); same single statement, same conflict target. |
| O9 | Execution | Timestamps formatted in SQL (`to_char(...)`) | Recommended | Read as `utcTimestampField`, formatted in Haskell to the same text (to the second, UTC). |
| O10 | all | Identifiers are untyped `T.Text` throughout (an Engineer id and a repository id have the same type) | Recommended — deferred | Typed id newtypes would change the Application layer's signatures across the code base; out of scope for a localized pass. |
| X1 | Migrations | The schema is SQL DDL in an append-only, checksummed migration list | Acceptable exception | The migration ledger verifies every applied migration's checksum (C-P1.2); Orville's auto-migration would compute DDL from table definitions and change schema-management semantics, triggers and partial indexes. The table definitions in this pass describe the existing tables and are never used to migrate. |
| X2 | Projects, Tasks, Profiles, Repositories | `LOCK TABLE ... IN EXCLUSIVE MODE` | Acceptable exception | Orville has no table-lock statement; constant text, no parameters. |
| X3 | SessionLocks, Ledger | `SET lock_timeout` (a `SET` takes no parameters; the value is an `Int`), the `pg_locks` probe (the key a parameter), and the scheduler's `pg_advisory_xact_lock(hashtext('lockstep-scheduler'))` (constant text) | Acceptable exception | PostgreSQL session facilities Orville does not model (C-C.R1 R1, R5). The session lock and unlock are typed function calls, as is `lockEngineer`; the scheduler lock could be one too (Recommended, left unchanged after the final qualification run). |
| X4 | Ledger | `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY` inside an open transaction | Acceptable exception | Orville sets isolation only when it begins a transaction; the caller's is already open (C-P2.9-R1 M3). |
| X5 | Jobs | The job claim and the in-update outcome digest | Corrected (was planned as an exception) | Both are expressible with Orville's expression builders and stay single atomic statements: `UPDATE ... WHERE id IN (SELECT id ... ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING ...` with `CASE`, `coalesce` and `make_interval` set clauses, and `outcome_digest = sha256(convert_to(... \|\| ..., 'UTF8'))` in the finishing update. |
| X6 | Migrate, Migrations | Migration application through libpq's simple-query protocol; the DDL itself | Acceptable exception | Schema management: migrations hold several statements, which Orville's parameterised execution cannot run (see X1). The ledger probe (`to_regclass`) and ledger read are now typed. |
| X7 | Fields | Two SQL tokens Orville 1.1 has no constructor for: the `bytea` data type name of the digest field, and `DO NOTHING` after a conflict target (Orville exports DO NOTHING only without a target) | Acceptable exception | Named once, in `Lockstep.Persistence.Fields`. |

**Status:** O1–O9 corrected (`7745e3c`, `1d1f40b`). What remains as SQL in `src/Lockstep/Persistence` is listed in
X2–X7. Text values are always typed parameters; the only values written into SQL text are two internal integers in
X3 (the lock timeout in seconds and the lock namespace).

## 2. JSON (json-fleece)

Decoding was already sound (strict Fleece schemas for `lockstep.json`, Profile documents, role answers, evidence
records). Encoding never used Fleece.

| # | Where | Finding | Class | Correction |
|---|---|---|---|---|
| J1 | `Web/SecureResponse.hs` `jsonString` | Characters above U+FFFF are written as `\u` + 5 hex digits, which is not JSON (a parser reads U+1F60 then `0`). Every JSON response passes through it. | Required | Responses are encoded by Fleece; the markup-safety pass (`<`, `>`, `&` and non-ASCII as `\uXXXX`) runs over the encoded text and writes astral characters as surrogate pairs. |
| J2 | `Web/SecureResponse.hs` `errorJson`, `Web/Control.hs`, `Web/App.hs` | Every JSON response body assembled from strings | Required | One Fleece schema per response body (`Web/Json.hs`), encoded with `FA.encode`. Field names, order, null and omission semantics unchanged. |
| J3 | `Application/Engine.hs`, `Application/EngineCandidate.hs` (with `Foundation/Json.hs`) | Every transaction record, the candidate, the discovery and the frozen Contract built as a hand-made JSON tree; several read back through separate private Fleece decoders (two representations of one payload); acceptance read records by substring search | Required | Corrected: one schema per record kind (`EngineRecords`) for writing and reading; candidate and discovery through the role-answer schemas; acceptance decodes. Byte-identical to the old output (compliance suite), so `body_digest` and `contract_digest` are unchanged; the discovery record's key order follows its answer schema. |
| J5 | `Application/Engine.hs` role context documents | Composite documents that embed stored records verbatim (`JRaw`) | Acceptable exception | Fleece has no raw-JSON embedding; re-encoding stored records would change what the role sees. Kept in `Foundation.Json`, whose escaping was verified byte-identical to Fleece-aeson. |
| J6 | `Application/Execution.hs`, `Application/ProjectChecks.hs` | Built-in Profile documents written as JSON text (old audit J3) | Recommended | Corrected: through the Profile document schema; byte-identical (stored digests reproduce). |
| J4 | `Kernel/EventCodec.hs`, `Kernel/Profile.hs` rendering, `Kernel/Conversation.hs` payload texts, the control and runner line protocols | Not JSON: canonical digest or protocol texts | Not a finding | — |
| J7 | `Effects/Provider/Claude.hs` | JSON-like text in the role instructions | Not a finding | Prose describing the answer format to the model. |

## 3. HTTP, HTML and browser code (Orb, Beeline, Brigid, HTMX)

From a read-only survey of `src/Lockstep/Web/**`, `app/` and `static/` against Launchpad `Routes/` and
`Components/`.

| # | Where | Finding | Class | Disposition |
|---|---|---|---|---|
| W1 | `Web/App.hs` `matchAppRoute`, `Web/Operator.hs` `matchOperatorRoute`, `Web/Application.hs` dispatch chain | `/app` and `/operator` are routed by hand (`pathInfo` patterns) in front of the Beeline tree; only health, readiness and liveness are Beeline/Orb routes | Required | Deferred, see §5 |
| W2 | `Web/App.hs` and `Web/Control.hs` `shell` | Full HTML documents as string lists | Required | Control pane: corrected (Brigid, `Components/Shell`, links from the static route). Application: acceptable exception: the frozen C-P3.4 test pins the `htmx-config` attribute as single-quoted raw JSON (`"allowEval":false`), and Brigid writes double-quoted attribute values as given, so the bytes cannot be produced without breaking the attribute. |
| W3 | `Web/Control.hs` | The control pane is its own WAI application with its own route matcher | Recommended | Deferred with W1 |
| W4 | `Web/App.hs`, `Web/Operator.hs`, `Web/Control.hs` | Form bodies read and parsed by hand; responses built with `Wai.responseLBS` | Recommended | Deferred with W1. The 16 KiB/1 MiB limits and the security header values stay. |
| W5 | Brigid pages | Internal links are string literals, not route builders | Recommended | Follows W1 |
| W6 | `Web/Application.hs` `staticResponse`, `notFound` | Responses without the security headers the other responses carry | Recommended | Corrected (`respondWith`) |
| W7 | `Web/RequestGuard.hs`, `Web/SecureResponse.hs` headers | Exact Host/Origin checks and CSP headers in low-level code | Acceptable exception | Security-motivated (C-P1.3 E7), pure |
| W8 | `Web/Fragment.hs` | Attribute values escaped before `customAttribute`; numeric entities rewritten to named ones | Acceptable exception (verified) | Verified in this pass: Brigid 0.4 writes attribute values as given (a JSON value's quotes came out raw), so the manual escaping is required (C-C.R1 R8). |
| W10 | `Web/Components/Shell.hs` | `-freduction-depth=400` for one module | Acceptable exception | Brigid's type-level content check for `noscript` under `body` needs more than GHC's default 200 steps; the check runs in full. |
| W11 | `Web/Static.hs` | Template Haskell (`file-embed`) embeds the static assets | Not in scope | Recorded for the Simple Haskell audit (no TH); not a stack bypass. |
| W9 | `static/app.js` (256 lines), `static/control.js` (662 lines) | `app.js` repeats the server's route table on the client; `control.js` is a fully client-rendered UI | Recommended | Deferred; tied to the header-only session design (C-P3.1 §3) |

## 4. Core logic and verification

No finding: the Kernel stays pure (henforcer and the C-P2.1 boundary scan), and verification uses the existing
deterministic suites.

## 5. Deferred decisions

- **W1/W3–W5 (routing and request handling).** Moving `/app`, `/operator` and the control pane onto Beeline routes
  and Orb handlers changes every route's recognition, response alternatives and status handling in front of about
  60 frozen integration tests and the browser drivers. It is an HTTP-layer rewrite rather than a localized
  correction, and is recorded for its own increment.
- **O10 (typed identifiers).** Changes signatures across Application, Web and tests.
