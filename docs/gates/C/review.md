# Gate C — independent read-only review and proposed dispositions

- Reviewer: a separate **read-only** reviewer agent of the same model family as the writer. It was
  told to read files and use read-only git only, with no edit, build, Docker or network use.
  **This is not a human review.**
- Scope: `git diff 8e71039..0c8d9ee -- src app scripts static lockstep` (Phase 3 production code),
  against C-P3.1–C-P3.10; mostly P3.5–P3.10. It did not read Brigid's source (outside the
  repository) and ran no tests.
- Date: 2026-10-27. Result: **no HIGH findings**; 2 MEDIUM, 5 LOW, 3 INFO.
- Dispositions are **proposed** by the writing agent (Implementer). Nothing has been changed; the
  tested commit stays `0c8d9ee`. Items marked **owner** need the owner's decision. (Superseded:
  the Planner decided them on 2026-10-27; see "Planner dispositions" below.)

## Findings and proposed dispositions

| # | Sev. | Finding (reviewer's words, condensed) | Proposed disposition |
|---|---|---|---|
| 1 | MEDIUM | `applyDecision` (`Application/Decisions.hs:179-215`): key lookup, operation and receipt insert are three steps. Two concurrent requests with one key: one applies, the other is refused stale; if the refused receipt is inserted first, the applier gets back "refused" (no digest check on the lost-race path, line 210), the only durable receipt contradicts what happened, and the closed decision's page 404s (`decidedReceipt` only reads `applied`). Same root as the limitation recorded in C-P3.8 §3a. | **Fix before acceptance** (owner to confirm): claim the key first: a transaction-scoped advisory lock on the key spanning check, operation and insert is not possible because the ledger operations own their transactions; instead insert a `pending` receipt row first (migration 16 widening `outcome`), then update it once with the result. That breaks the "rows never update" rule of M4, so it needs the owner's choice between (a) pending-then-final with a one-time update allowed, or (b) a session-level advisory lock held across the three steps. Also compare digests on the lost-race path. No double effect is possible today (revision/generation checks), only a wrong receipt. |
| 2 | MEDIUM | `connectProject` (`Application/Projects.hs:159-204`) checks the revision before side effects: two concurrent connects at one revision both make a folder, an Engineer and a repository registration, then one is refused `stale-revision`, leaving an orphan Engineer owning a repository (C-P3.5 J2 says a stale revision "changes nothing"). Also on `Left` after the folder was made. | **Fix before acceptance** (owner to confirm): serialise per project before any side effect with a session-level advisory lock keyed on the project id, re-reading the revision under it. Needs a frozen-test addition (a concurrent-connect case). |
| 3 | LOW | `scripts/control-helper:897-906`: `folder_refusal` runs in a subshell, then again only to set `folder_real`, with that second run's refusal discarded; a symlink re-targeted between the two runs could be added as `ro`. | Fix with 2 (single in-shell check setting `folder_real` and `refusal`). Requires a local race on the owner's own home folder. |
| 4 | LOW | `scripts/service:105-130`: `folder_args` follows symlinks with `[ -d ]` and never re-checks that a listed folder is still a real directory inside `$HOME` before mounting. | Fix with 3: skip `[ -L ]` entries and compare `pwd -P`. |
| 5 | LOW | `expected` is an unbounded `Int` stored as `Int32` (`App.hs:404`, `Decisions.hs:194`, `DecisionReceipts.hs:83`): `-1` or `2^31` → refused, then the receipt insert fails (503, no receipt) or wraps. | Fix: reject outside 0..2³¹−1 as a form error before `applyDecision`. |
| 6 | LOW | A closed decision's page shows the latest *browser* receipt for the subject, even from an earlier halt cycle when the latest one was settled elsewhere (`App.hs:507-512`). | Fix: show the receipt only if newer than the subject's last ledger event; else "decided elsewhere". |
| 7 | LOW | `decideTask` is not under the task lock as C-P3.6 K2 says, and `lockTasks` locks the whole table, not one project's tasks; a concurrent title edit and decision can collide on the Ticket's event revision, surfacing as 503 instead of `stale-revision` (nothing half-applied). | **Owner**: either amend the K2 wording to match (decisions go through C-P2.2 `decideTicket`, revision-checked), or run the decision inside the edit lock and map the conflict to `stale-revision`. Proposed: the latter. |
| 8 | INFO | `Fragment.attr` relies on Brigid escaping `"` in `customAttribute`; no test echoes a `"` into an attribute value. | Add a test with a title containing `" autofocus onfocus=alert(1) x="` (a new frozen case, owner-visible). |
| 9 | INFO | A reused creation key returns the earlier task/project even when the new request names another project; `CreateTaskRoute pid` can answer with another project's task. | Return `key-conflict` when the project differs (matches C-P1.5's key rule better; small contract amendment). |
| 10 | INFO | `none` is the "nothing chosen" sentinel for `expected` in the checks form; a profile registered with id `none` would be confused with it. | Reserve the id `none` (refuse it in `profile add`), or use an impossible sentinel. |

## Planner dispositions (2026-10-27) and what was done

The Planner decided all ten (`.local/plans/phase-03_update2.md`); the remediation is contract
**C-C.R1** (`docs/gates/C-R1/contract.md`), frozen before the code changed.

| # | Planner's decision | Done in C-C.R1 | Open |
|---|---|---|---|
| 1 | Option B: session-level advisory lock over lookup → operation → receipt; digests on every replay path; bounded wait; fail closed | R1, R2: dedicated lock connection, 5 s bound (`decision-busy`), attempt marker before the operation, lock proved held before the receipt insert, `decision-outcome-uncertain` instead of a replay or a guessed receipt; receipts still insert-only | — |
| 2 | Serialize per project, re-read under the lock, no orphans | R5: per-project lock; Engineer, registration and setup in one transaction; a folder the attempt made is removed unless connected | — |
| 3–4 | One check; reject links and escaped paths before mounting | R6 | the helper's check-to-write window has no deterministic test (C-C.R1 §3) |
| 5 | Refuse out-of-range revisions before any operation or receipt | R3 | A-C.R1-2 (a frozen page case's own fixture is wrong) |
| 6 | Compare the receipt's ledger basis with the subject's latest | R4 | — |
| 7 | Enforce K2 in code; stale → typed `stale-revision` | R7 | — |
| 8 | Test quoted attributes through the renderer and a browser | R8 (and `attr` escapes `"` itself) | — |
| 9 | Bind replay to the project and the request | R9: another project's key is `key-conflict` | the same key with other content: **A-C.R1-1**, contradicts frozen C-P3.5/C-P3.6 tests |
| 10 | An unambiguous form value, no restricted IDs | R10: `expected_set`; old `none` fails closed | — |

## Checked and found clean (reviewer's list, condensed)

Route guard (every data-carrying or acting `/app` route needs the session header, exact Host and
Origin on POST; OPTIONS 405; no CORS); principals (browser decisions always Human; no request field
names a principal); SQL parameterised everywhere; host folder choice limited to offered paths with
path syntax rejected; the schedule preview read-only (first statement `SET TRANSACTION … READ ONLY`,
no lock/claim/row); `chooseChecks` one transaction under the profile lock with stale, losses and
refusal rows as contracted; `createTask`/`editTask` revision-guarded twice under the lock; Activity
and status words honest (PASSED only for PASSED, ATTESTED not verified, unknowns never success, an
unreadable projection never empty); decision kinds checked (`fits`), Give up re-checks the
generation, Try again needs the acknowledgment, text rules before any receipt; sign-in tokens only in
URL fragments, cleaned from the address bar.

## Review 2 — the remediation diff (C-C.R1)

- Reviewer: a fresh, separate **read-only** reviewer agent of the same model family (read files and
  read-only git only; no edit, build, Docker or network). **Not a human review.**
- Scope: `git diff 7839c21..e49b68e -- src app scripts static lockstep`, against C-C.R1 R1–R12, the
  findings above and the Planner disposition. Date 2026-10-27. Result: **no HIGH, no MEDIUM**;
  4 LOW, 4 INFO.

| # | Sev. | Finding (condensed) | Disposition |
|---|---|---|---|
| 1 | LOW | The marker path answers `decision-outcome-uncertain` without comparing digests; the disposition asks for a digest comparison on every replay/conflict path | **Fixed in `e1c56ef`**: the marker's digest is read; another digest is `key-conflict`, the same is `decision-outcome-uncertain` |
| 2 | LOW | A failed `pg_advisory_unlock` after a committed receipt answers "unavailable" for an applied, receipted decision | **Fixed in `e1c56ef`**: the unlock is best effort; closing the connection releases the lock |
| 3 | LOW | A folder the attempt made survives an exception thrown before the attempt settles | **Fixed in `e1c56ef`**: removed on any exception (`onException`) |
| 4 | LOW | The launcher compares one link level literally; a relative or chained link to this Lockstep is reported as another program | **Fixed in `e1c56ef`**: the whole link chain is followed |
| 5 | INFO | One new pool (one connection) per locked request, outside the service pool's cap | **Deferred to Phase 4** (Planner, 2026-10-27): a bounded-concurrency concern that must be addressed before concurrent live-engineering workloads (cap the number of lock connections, or share a bounded lock pool) |
| 6 | INFO | Async exceptions inside the lock become "unavailable" (as `withDatabase` already does) | **Accepted as documented** (Planner): it fails closed (marker stays, connection destroyed) |
| 7 | INFO | A marker left by an unavailable database poisons that key | **Accepted as documented** (Planner): intended (R1); a reloaded page has a fresh key |
| 8 | INFO | The PATH warning repeats on every interactive launch while shadowed | **Accepted as documented** (Planner): intended (R12) |

Planner disposition of Review 2 (2026-10-27, `.local/plans/phase-03_update3.md`): the four LOW
corrections in `e1c56ef` are **accepted provisionally**, subject to a narrow read-only review of the
`e49b68e..e1c56ef` delta (Review 3, below).

## Review 3 — the review fixes (`e49b68e..e1c56ef`)

- Reviewer: another fresh **read-only** reviewer agent (same rules). **Not a human review.** Scope:
  `git diff e49b68e e1c56ef`. Result: **no HIGH, no MEDIUM**; 2 LOW, 2 INFO.
- The tested commit stays `e1c56ef`: the owner asked that no new Mac qualification run yet, so the
  proposed changes below are **not made**. They are small and go with the next code change, which
  the A-C.R1-2 re-freeze needs anyway (one qualification for both).

| # | Sev. | Finding (condensed) | Proposed disposition |
|---|---|---|---|
| 1 | LOW | The best-effort unlock's `try` (`Database.hs`, `withSessionLock`) also catches asynchronous exceptions, so a thread kill during the unlock is swallowed. The lock is still released (the one-connection pool is destroyed) | Rethrow asynchronous exceptions there (catch synchronous ones only) |
| 2 | LOW (contract text) | Frozen C-C.R1 R1 step (2) says a marker without a receipt is `decision-outcome-uncertain`; since `e1c56ef` a marker with **another** digest is `key-conflict` (as the Planner's "compare digests on every path" requires). No frozen test covers that branch | **Planner**: amend R1 (2) to "… same digest → `decision-outcome-uncertain`, other digest → `key-conflict`" and add a frozen case for it (A-C.R1-3, to be written with A-C.R1-2's re-freeze). Until then the contract text trails the code on this branch |
| 3 | INFO | An asynchronous exception after the project transaction committed `connected` but before `settle` returns would remove the folder the project now records | Re-read the project before removing a made folder; remove only if it does not record that folder |
| 4 | INFO (older) | An ambiguous COMMIT (committed on the server, a connection error on the client) also removes a recorded folder | The same fix as 3 |

The four points the Planner asked Review 3 to verify:

| Point | Verdict | Basis |
|---|---|---|
| Markers tell same-digest uncertainty from other-digest conflict | **Verified in code** (receipt first, then the marker's digest: other → `key-conflict`, same → `decision-outcome-uncertain`); **not covered by a frozen test**, and frozen R1 (2) text trails it | Review 3 "checked clean"; finding 2 → A-C.R1-3 |
| Post-commit lock cleanup cannot turn an applied, receipted action into a false refusal | **Verified**: a failing unlock is ignored and the result returned; the one-connection pool is destroyed, so the lock never survives on a reused connection. Residue: finding 1 (an async kill during the unlock is swallowed; it is not a refusal) | Review 3 finding 1 and "checked clean" |
| Exception cleanup cannot delete a directory after a successful connection, or anything the attempt did not create | **Not fully met.** Nothing the attempt did not create is ever removed (only the folder `makeProjectFolder` made, after a real-directory check). But a folder a *successful* connection records can be removed in two narrow windows: an asynchronous exception after the commit (finding 3) or an ambiguous COMMIT (finding 4) | Review 3 findings 3, 4 |
| Chained symlink resolution handles cycles and foreign targets safely | **Verified**: at most 20 links, cycles and dangling targets reported as another program, relative links resolved against their own directory, nothing changed on disk | Review 3 "checked clean" |

### Correction plan for the remaining findings (not applied; no qualification started)

1. Point 3 / findings 3, 4 (`Application/Projects.hs`, `attempt`/`settle`): before removing a made
   folder, on the normal path and in the exception handler alike, re-read the project (`findProjectById`
   on the service pool) and remove the folder only when the project does **not** record it as its
   folder. If that read fails, keep the folder: a possibly orphaned new folder is preferred to
   deleting a connected project's folder. Test: inject a failure *after* the commit (a trigger cannot
   do that; a test fault hook in `settle`, as C-P2.5's `Faults`, is needed), and an ambiguous-commit
   case if it can be forced.
2. Finding 1 (`Application/Database.hs`): catch only synchronous exceptions around the unlock and
   rethrow asynchronous ones.
3. Finding 2: A-C.R1-3 (contract text and one frozen case).

These, together with A-C.R1-1's production change and the A-C.R1-2 / A-C.R1-3 re-freezes, need one
new Mac qualification and one Linux clean clone, which wait for the owner (stop instruction of
2026-10-27).

**Outcome (2026-10-27):** the Planner gave final authorization (`.local/plans/phase-03_update4.md`)
for the three amendments and the corrections above; all were applied (`e679d97`, `d064150`; C-C.R1
§3b).

## Review 4 — migration 17 and the Review 3 corrections (`e1c56ef..d064150`)

- Reviewer: a fresh **read-only** reviewer agent (same rules). **Not a human review.** Scope: `src`
  of `e1c56ef..d064150`, with the test amendments of `e1c56ef..e679d97` for intent. Result:
  **1 MEDIUM**, 1 LOW, 3 INFO.

| # | Sev. | Finding (condensed) | Disposition |
|---|---|---|---|
| 1 | MEDIUM | R13 re-read only the attempt's own project. A folder `git init` has just made is offered to every other project at once, so another project can connect it while the attempt runs; if the attempt then fails, it removes a folder that project is connected to | **Fixed in `b9f7d47`** (C-C.R1 §3c R13a, R13b), under the Planner's authorization ("preserve the folder if it is connected"): the check and the removal run in one transaction under the projects lock and keep any folder any project is connected to; and an attempt is recorded as connected only if its folder is still there, under the same lock. Both orders of the race are frozen cases (`GateCRemediationFolderRaceTest.hs`), failing before the fix |
| 2 | LOW | A dependency that is not a task id went into the task's canonical text unquoted, so joined text could equal another list and replay | **Fixed in `b9f7d47`** (R9a): each dependency quoted; frozen case |
| 3 | INFO | Asynchronous exceptions inside the locked work still pass through `withDatabase`, which turns them into a database failure | Kept: R14 leaves `withDatabase` unchanged on purpose; the outcomes are safe (a failed read keeps the folder) |
| 4 | INFO | A synchronous failure while destroying the lock's pool (after the `try`) would escape as an exception | Kept: not new; noted |
| 5 | INFO | A row made before migration 17 whose project or task changed since now refuses its own replay | Intended (R9: fail closed) |

## Review 5 — the second addendum (`d064150..b9f7d47`)

- Reviewer: a fresh **read-only** reviewer agent (same rules). **Not a human review.** Result:
  **no HIGH, no MEDIUM**; 3 LOW, 1 INFO. R13a/R13b serialization, lock order, R9a, R15a and the frozen
  expectations checked clean.
- **Not fixed** (each needs its own frozen case; held for the Planner so that the remediation stops at
  a qualifiable commit rather than another fix-and-review round). Correction plan below.

| # | Sev. | Finding (condensed) | Proposed correction |
|---|---|---|---|
| 1 | LOW | R13a compares folders by path text. An added folder that names the same place as a projects-folder child under another spelling (a symbolic-link parent, or other letter case on a case-insensitive disk) is not seen as connected, so a failed attempt can still remove it | Under the projects lock, keep the folder when any active repository row has the same physical identity (common directory / physical id) as the folder, not only the same path text |
| 2 | LOW | R13b checks only that something is at the path; if the folder was removed and a new one made at the same path, a waiting attempt records its stale observation | In the attempt's transaction, re-observe the folder's identity and compare it with the observation; differ → `folder-not-offered` |
| 3 | LOW (older code) | `makeProjectFolder` removes its folder when `git init` fails, outside the lock and the database checks; if `.git` already exists another request could connect it first | Make the folder under a temporary name and rename it into place only after `git init` succeeds (nothing is offered until then) |
| 4 | INFO | Tasks created at `d064150` with the earlier unquoted format would conflict on replay (fails closed; that format was never released). Removal holds the projects table lock while deleting a fresh folder (bounded; reads still allowed) | None |

All three need an operator-made folder alias or a second near-simultaneous attempt on the same
folder; none affects a single person using the pages in order. The Planner decides whether they are
fixed before the consolidated qualification (one more small addendum, frozen first) or recorded as
Gate C exceptions.
