# Contract — P4.10–P4.14 The Implementer, verification, the challenge after it, review and acceptance

- Contract ID: `C-P4.10-14@v1` (one Contract for the five sub-phases of one stage chain)
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.10 ("exactly one production-writing Implementer … Constrain filesystem, tool,
  process, network and credential capabilities … Test forbidden code edits, test edits, Git commits, credential
  access, unauthorized network activity and scope expansion"), P4.11 ("the exact candidate revision … Partial,
  stale, dirty, timed-out or missing results cannot count as green"), P4.12 ("wrong-but-green implementations …
  typed counterexamples"), P4.13 ("a separate read-only review … unable to change production code, tests,
  Contracts or canonical Git history"), P4.14 ("the Supervisor create the accepted implementation commit …
  an Implementer cannot commit as the Supervisor, rejected review blocks acceptance, and stale or dirty Git state
  cannot be accepted. No automatic push"); DG-17 (D-17.2 Git-free snapshot, protected tests read-only, the
  Supervisor checks changed paths, file types, revision identity; ≤ 2 Implementer attempts); DG-06 D-6.5; DG-07
  (post-implementation dispositions); C-P4.2, C-P4.4, C-P4.5, C-P4.6, C-P4.7–9.
- Writer: the single writing agent (Implementer, manual).
- Scope: the stages `implement`, `verify`, `challenge-post`, `review`, `accept`. The person's Done, resume after a
  halt and the pages are P4.15–P4.16. The container boundary for the Implementer is C-P4.2's (host check); in
  this suite the roles run on the direct runner, which is no boundary, so every guarantee below is the
  Supervisor's own observation after the run.

## 2. Decisions

| # | Decision |
|---|---|
| I1 | **Implement**: the Implementer (write profile; the protected tests passed as protected paths, mounted read-only by the container runner) on a Git-free snapshot of the freeze commit; context: Ticket, Contract record, allowed paths, protected tests, earlier refusal/verification/finding/review records — never another role's transcript. Then the Supervisor's comparison (C-P4.4 G5) against the freeze tree; refused as one attempt (`ImplementationRefused`): a link, special file or `.git` (G5 codes), `protected-test-changed`, `change-outside-scope`, `no-change`. Otherwise the Supervisor commits the changes on top of the freeze commit, by its identity, at the freeze commit's time + the attempt number (deterministic), on **no** branch: the candidate commit. Records `implementation` (the Implementer's summary as text, changed paths, candidate commit, attempt) / `implementation-refused`. |
| V1 | **Verify**: a fresh snapshot of the exact candidate commit; every protected test there must have its frozen bytes (`protected-test-changed`, halt); every verification command and every frozen test runs (command limits). All exit 0 → passed; a missing program → `verification-environment-missing`; a run that did not end normally (timeout, too much output, held, cancelled, launch failure) → `verification-run-failed` (both halt: never green); any other failure → failed (another attempt if one is left, else `attempts-exhausted`). Records `verification` per command and `verification-summary` (the commit, passed). |
| C1 | **Challenge after**: the challenger (read-only) on the candidate commit; context: Ticket, Contract, the candidate commit, the verification records — not the Implementer's summary. A finding's test (a new path, not an existing or allowed one) is added by the Supervisor to a fresh copy of the candidate and run: failing with its signature is an observed counterexample (`survived-demonstrated`), passing is `killed`; K3 disposes. `CONFIRMED` → another attempt (feedback to the Implementer), `NEEDS_HUMAN` → halt. Records `post-finding`. |
| R1 | **Review**: the Reviewer (read-only) on the candidate commit; context: Ticket, Contract, candidate and freeze commits, verification records and every finding — not the Implementer's summary. `approve` → accept; `reject` → another attempt; `needs-human` → halt. Record `review` (commit, verdict, reasons, invocation). |
| A1 | **Accept**: only if the latest verification summary passed for the candidate commit and the latest review approved that same commit, the Engineer still owns the repository, and the work branch is still at the freeze commit; then the branch moves to the candidate by compare-and-swap (C-P4.4 G6) — never a checked-out branch, never anything else (no push, no other ref). Record `acceptance`; the transaction is `accepted` (awaiting a person). Any failed condition halts with its reason. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EngineImplementTest.hs` | integration: real PostgreSQL, Git, processes; all four roles scripted | I1 the fix as the Supervisor's candidate commit (author, parent, only the allowed file, its bytes) and V1 passed on that exact commit; I1 refusals: a protected test, a path outside the scope, a `.git`, a link, no change — each one attempt, the branch untouched; V1 failing fixes use the second attempt then `attempts-exhausted`; C1 a wrong-but-green fix: the counterexample CONFIRMED, the second attempt accepted with the right bytes; R1 a rejection uses an attempt, needs-human halts with a request; A1 the branch moves from the freeze to the exact reviewed commit by the Supervisor, `main`, the checkout and remotes unchanged, accepted is final for the engine; a branch moved by someone else is never accepted over; the challenger and the Reviewer never receive the Implementer's words |

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the five stages were wired into the engine.

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/EngineImplementTest.hs` | `12a210b14cda2c0d2f0f334983ab11af4577ca9a9947399c743a09bf3456b8bb` |
| `test/integration/Main.hs` (runner, additive) | `e0c100598e216c12d81ec28a38b68849de316d29e6389be5804c1059a24ece1d` |

Pre-freeze verification (logs in this directory):

- The engine was the C-P4.7-9 engine (the five stages `stage-not-built`); the scripted role's `copy_context`
  step was already committed (`be020cc`). Build, format and lint clean.
- Integration baseline (`prefreeze-integration-baseline.log`): **8 of 8 fail** at the implement stage
  (`stage-not-built`), after the six earlier stages ran for real. One assertion was then rewritten for a lint
  hint (a `let` instead of `pure`), with the same meaning.
- Fixture trial against the five stages (`fixture-trial.log`): **8 of 8 passed** at the first run; no assertion
  needed correcting. The C-P4.7-9 engine was put back for this freeze commit.

## 5. Allowed paths

Changed: `src/Lockstep/Application/Engine.hs` (the five stages; protected paths for a role run),
`scripts/runner/scripted-role` (the `copy_context` step), `lockstep.cabal` (generated), the integration runner
(additive), `docs/gates/P4.10-14/**`, `docs/gates/C-EXEC/phase-report.md`. New: the test file.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
