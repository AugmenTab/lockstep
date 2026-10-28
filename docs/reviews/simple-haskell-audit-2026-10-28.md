# Simple Haskell audit — 2026-10-28

- Asked by the owner: inspect the codebase for Template Haskell, lenses, `undefined`/`error`, uncaught
  exceptions and partial functions.
- Method: a read-only survey (grep and reading, no builds) of `src/`, `app/`, `test/` and the unbuilt Phase 4
  drafts in `.local/p4*-draft`, at `381e334` plus the uncommitted P4.2 pre-freeze files.
- **Report only.** Nothing in accepted or frozen code was changed. Fixes to existing code need the owner's go-ahead
  (and, for frozen tests, an amendment decision). New Phase 4 code follows the rules from now on.

## Verdict

Production code is disciplined: no `undefined`, `error`, `fail`, lenses, `unsafe*`, `Debug.Trace`, orphan
instances or unguarded partial functions. `-Weverything -Werror` makes incomplete and irrefutable patterns,
partial record fields and orphans compile errors; `.hlint.yaml` bans the Prelude/Data.List partials, `error`,
`undefined`, `read`, `fromJust`. **The real risk is exception handling**, concentrated in two existing
modules and in the newest Phase 4 code.

## What is already enforced, and the gaps

Enforced automatically: incomplete/irrefutable patterns, partial fields, orphans (compiler); Prelude/List
partials, `error`, `undefined`, `read`, `fromJust` (hlint, with a fixture proving the rules are live); Kernel
purity and layering (henforcer, the Kernel scan).

**Not checked by anything:** partial functions from other modules (`T.head`, `BS.head`, `Map.!`,
`Map.findMin`, `NE.fromList`, `digitToInt`, `chr`, `div`/`mod` by a variable); strict `TE.decodeUtf8`; pure
`throw`, `throwIO (userError …)`, `ioError`; `unsafePerformIO`/`Debug.Trace` outside the Kernel; lazy IO;
`try` on `SomeException` that also swallows asynchronous exceptions; `TemplateHaskell` or any other pragma;
IO in Effects/Application that can throw unhandled.

## Findings — production code (src/, app/)

| # | Severity | Where | What | Simpler alternative |
|---|---|---|---|---|
| P1 | MEDIUM (highest impact) | `Application/Database.hs:145` | `withDatabase` does `try` on `SomeException`, so **asynchronous** exceptions (thread kill, `timeout`, Warp's request timeout) become `DatabaseError`. An executor timeout around a sandbox adapter is swallowed and reported as `adapter-failed`, and the action keeps running. Contradicts the module's own rule in `withSessionLock` (C-C.R1 R14). No corruption (Orville rolls back). | rethrow when `isAsynchronous` (the module already has it), or `UnliftIO.try` / `safe-exceptions` `try` (synchronous only) |
| P2 | MEDIUM | `Application/Dispatcher.hs:150, 154` | `try` on `SomeException` around claim and run: a kill is logged as "stopped by an error" and the loop continues; a job killed mid-step is not released. Works today only because shutdown goes through the MVar. | `tryAny` (synchronous) or rethrow async |
| P3 | MEDIUM | `Application/Profiles.hs:150` (CLI `profile add`), `Foundation/SystemConfig.hs:173` (LOW, start-up) | lazy `LBS.readFile`/`getContents` inside `try`: only the open is caught; a read error escapes later from pure decoding. SystemConfig also checks permissions and then reads (a small race). | strict `BS.readFile`, then `LBS.fromStrict` |
| P4 | MEDIUM | `Application/Repositories.hs:220` (+ `Profiles.hs:127`, `Repositories.hs:116`, `Command.hs:397`, `Ledger.hs:516, 737` LOW) | `throwIO (userError …)` for invariant violations inside Orville; an integrity failure surfaces as a generic database error | a typed `Left` (e.g. `LedgerIntegrity`) from the Orville block |
| P5 | LOW | `Web/Application.hs:105` | logs `show` of the whole exception (may include SQL or request text); the dispatcher deliberately logs only the type | log the type, as the dispatcher does |
| P6 | LOW | `Web/Static.hs` | Template Haskell `embedFile` for the four static assets | acceptable as is; or generate a module at build time / read from the install directory |
| P7 | LOW | 12 modules, ~135 sites | `[Interpolate.i|…|]` quasiquotes, **all without interpolation holes**: plain literals | `OverloadedStrings` / `T.pack`; `T.unlines` for the multi-line SQL in `Migrations.hs` and `Migrate.hs`. Would remove the string-interpolate dependency and hlint's `-XNoCPP` workaround |
| P8 | LOW | Web/ (Readiness, Liveness, Health, Routes, NoPermissionError) | `DataKinds`, `TypeFamilies`, one `UndecidableInstances`, required by the Orb/Beeline APIs | keep confined to Web/ |
| P9 | LOW | ~25 sites | `L.nub` (quadratic) on small, bounded lists | `Set` if a list can grow |
| P10 | LOW | `ControlPane.hs:404–405` | a signed file is written, then made 0600: briefly umask permissions | create with mode 0600 |

Guarded and fine (checked): `digitToInt`/`intToDigit` uses behind `isDigit`/`isLowerHex`; `div`/`mod` by
constants; `Effects/Git.hs`, `ProjectFolders.hs`, `ControlPane.hs`, `Executor.hs`, `Reconciler.hs` exception
handling; `exitWith` only at start-up.

## Findings — tests (lower priority)

- `fromJust` in the new P4.2 `RunnerProtocolTest` — **fixed before its freeze** (hlint would have failed).
- ~33 lazy `System.IO.readFile` of logs that stub processes still append to (possible flakiness); 3 `try` on
  `SomeException` around them. In frozen tests: amendment only if a flake is observed.
- `throwIO (userError …)` as deliberate fault injection (~15 sites): intended.

## Findings — Phase 4 code not yet frozen (fixed in the implementation, before qualification)

| # | Where | What |
|---|---|---|
| D1 | `Effects/HelperRunner.hs` (P4.2) | `createDirectory`, `writeFile`, `setFileMode`, `renameFile`, `readFile` uncaught; a failure after the request is sent must be an **unknown outcome**, never an escaping exception; the request file briefly has umask permissions |
| D2 | `Effects/Process.hs` (P4.2 draft) | KILL to the process-group id after the leader may have been reaped (an unrelated group could reuse the id); `getPermissions` uncaught; `/dev/null` handle not bracketed; `waitFor` threads leak on an async exception |
| D3 | `Effects/GitSupervisor.hs` (P4.4 draft) | timeout path leaks handles and a reader thread and leaves a zombie; blobs read into memory without a cap; `ioError` used for control flow |
| D4 | `Effects/Roles.hs` (P4.5 draft) | `invokeRole` lets IO exceptions escape after a run is submitted (an unknown outcome would be lost); `readAnswer` checks with `lstat` then reads by path (a swapped-in link bypasses the regular-file and size checks: open with `O_NOFOLLOW`, read at most 256 KiB + 1) |

## Suggested follow-ups for the owner

1. Approve fixing **P1 and P2** (asynchronous exceptions swallowed) — the only items that change runtime
   behaviour of accepted code; each is a few lines, with a new test for a timeout around `withDatabase`.
2. Optionally P3–P5 (small), and P7 (mechanical, removes a dependency).
3. Optionally add automatic checks for the gaps above (hlint rules for `T.head`/`Map.!`/`NE.fromList`/
   `userError`/`unsafePerformIO`/`Debug.Trace`, and a pragma allowlist), so this does not depend on audits.
