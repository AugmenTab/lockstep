# Contract — P4.16 The task page shows the coding transaction and takes a person's decisions

- Contract ID: `C-P4.16@v1`
- Status: **FROZEN** (§4)
- Authority: Phase 4 handoff P4.16 ("Expose the active Work Unit in the existing authenticated UI, including
  criterion → method → actual result → evidence, effective Profile, attempts, implementation commit, semantic
  findings and reviewer verdict. Show unsupported, not-run and uncertain states truthfully. Provide the exact
  human review/Done action without silently marking work complete. Exit: A human can inspect and adjudicate a
  real engineering transaction from the normal application UI"); C-P4.15 H1 (a person's binding answer
  resumes its own halt), H2 (Done or not-done: a person's only, after acceptance); C-P4.1 X11 (the task page's
  Fixing it section, plain words, exact ids under Technical details); C-P3.7 (session and this origin for every
  action).
- Writer: the single writing agent (Implementer, manual).
- Scope: the task page's Fixing it section once Lockstep has started on the bug; two form actions. The service
  starting the engine worker is P4.17. Before a transaction exists the section is exactly as C-P4.1 froze it.

## 2. Decisions

| # | Decision |
|---|---|
| U1 | **Where it stands**, in plain words: working (and on which step), stopped and needing the person's decision (and why, in words), committed and waiting for the person, marked fixed, or stopped (by the person, as not fixed, or after a halt). |
| U2 | **Evidence**, read back from the engine's records (`EngineEvidence`): what the fix must do (each criterion and the task's words it rests on); how it is checked (each test and its command; the other commands); what the latest checks showed (each command: passed, failed with its exit status, did not finish in time, did not finish normally; what it printed); findings before and after the change and how each was disposed of; the reviewer's verdict and reasons. A part that has not happened yet says so (`Not written yet.`, `The checks have not run yet.`, `Not challenged yet.`, `Not reviewed yet.`); nothing not yet done is claimed. The verification record now carries the exit status (additive; older records read as "whether it passed was not recorded"). |
| U3 | **Not known**: a role run cut short (finished as uncertain) is shown as not known and not run again by itself; a record that does not read back is reported, never guessed at. |
| U4 | **Technical details**: transaction, Work Order, state with stage and code, effective Profile digest, basis commit, work branch, attempts, candidates, verified and reviewed commits, unreadable records, every run with its stage, outcome and id. Ordinary text has no internal words. |
| U5 | **A person's decision on a halt**: the halt's own request (read only — `haltRequest`, never opened by a page) is shown with its choices; `POST /app/api/transactions/<id>/decision` (`key`, `request`, `revision`, `choice`) records the person's binding answer through C-P4.3 (`SenderHuman ApplicationChannel`); the engine acts on it at its next step (C-P4.15 H1). A form for a request that is no longer the current halt's changes nothing and says so. No choice → asked to choose. |
| U6 | **Done or not**: shown only when committed; `POST /app/api/transactions/<id>/completion` (`choice` = `done` / `not-done`) calls `decideCompletion` as the person (application channel). Refusals in words: not ready yet, already decided, choose. Never marked done any other way. |
| U7 | Both actions: the session and this origin (401 / 403 before anything is read); an unknown transaction → 404; the answer is the task page with its address. `app.js` lets the two form actions through. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EnginePageTest.hs` | integration: the real service over HTTP, real PostgreSQL, Git and processes; the engine moved in-process with scripted roles | U1–U7: under way (step, criteria with the task's words, method, nothing claimed); halted (words, choices, 401/403, no choice, the answer recorded and the engine resuming on it, the old form refused); committed (checks passed with each command, nothing found, approved with reasons, Done once, then "already decided"); not done (early refusal, 401/403, unknown choice, stopped as not fixed, unknown transaction 404); cut short (not known, one run only); plain words in every state and escaped typed text |

## 4. Freeze record

- Frozen 2026-10-28 by the single writing agent (Implementer, manual), on `phase-4` after `23e4bd5`.
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EnginePageTest.hs` | `d1f79cf0bc8567256b144f2be2565de1f4961ff0461eda33f4057216183c1fc0` |
  | `test/integration/Main.hs` (one import, one group added) | `efcd9e438d36644bec4f3180c9f7f88561a91c57acd28f47c61ec92fe496f9f4` |

- Baseline at `stage-not-built` (the task and project pages are given no transaction; both actions answer
  `stage-not-built`): **6 of 6 fail**, each for that reason (`.local/p416-baseline.log`).
- Trial against the full implementation, before the stubs were put back: **6 of 6 pass**; every C-P4 group
  109 of 109, the frozen C-P4.1 page and browser groups among them; lint clean.
- Found while drafting and added to U1: the C-P4.1 lines "Nothing runs it yet", "Nothing has run yet" and "It
  cannot change it or run anything in it yet" would be false once Lockstep starts on a bug. They are shown
  only until then (the task: until its transaction exists; the project: until any of its bugs has one), so
  C-P4.1's frozen tests, which never start one, still see them.

## 5. Allowed paths

New: `src/Lockstep/Application/EngineEvidence.hs`, the test file. Changed: `src/Lockstep/Web/ExecutionPages.hs`,
`src/Lockstep/Web/App.hs` (two routes, the task page's transaction, the project page's started lines),
`src/Lockstep/Web/TaskPages.hs` (the header line until started), `src/Lockstep/Application/Engine.hs`
(`haltRequest`, `projectStarted`; the verification record's exit status),
`src/Lockstep/Persistence/Transactions.hs` (`projectStarted`), `src/Lockstep/Application/Conversation.hs`
(`requestByKey`, read only), `static/app.js` (two form actions), `lockstep.cabal` (generated), the integration
runner (additive), `docs/gates/P4.16/**`, `docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
