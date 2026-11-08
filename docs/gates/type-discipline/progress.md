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

Qualification (this Mac, Docker, `scripts/check --integration` on the Increment A working tree over `469c267`):
format, lint and static checks, build, unit **870/870**, guard, integration **571/571**, backup/restore — all PASSED
(`.local/td-check-A.log`); lockstep-compliance **32/32** (`.local/td-compliance-1.log`).

Behavioural differences (deliberate): an expected revision above `Int64` is refused (was wrapped); a Ledger revision
or generation above `Int32` is refused before anything is written (was wrapped into a refusal or observation row); a
corrupt setup or stage column is a read failure (was shown as organized / basis); `lockstep db migrate` prints
PostgreSQL's message after the existing sentence.
