# Contract — P4.5 Provider role adapters

- Contract ID: `C-P4.5@v1`
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.5 ("typed Planner, Implementer, Reviewer and semantic-challenger adapters,
  with reproducible scripted implementations for ordinary tests and configured real CLI implementations
  behind explicit authorization. Handle malformed output, prompt-injection content, partial output, timeout,
  provider crash, cancellation, quota refusal and uncertain outcomes. The provider family must not create
  additional execution authority"); **DG-17 ACCEPTED** (D-17.1 container per role; D-17.6 provider flags
  defence in depth only; D-17.7 limits; D-17.8 Claude Code first, interface provider-neutral; repository
  instructions are untrusted material; live provider calls separately authorized); C-P4.2 (runners);
  C-P2.6 X2 (unknown outcome); `engine-design.md` §2.
- Writer: the single writing agent (Implementer, manual).
- Scope: invoking a role once and typing what came back. Which role runs when, its context and what the
  engine does with an answer are P4.6 onward. **No live provider is built or invoked here**: the Claude CLI
  adapter needs the owner's separate authorization (DG-17 "live execution remains separately gated") and is
  recorded as NOT_BUILT in §3a; the interface takes it without change.

## 1. What P4.5 delivers

1. Typed role answers (`Lockstep.Kernel.Roles`) and the rules that keep an answer from widening anything.
2. Strict decoding of `result.json` (`Lockstep.Effects.Roles.decodeAnswer`): one shape per kind, unknown keys
   refused at every level.
3. One invocation path for every role and family (`invokeRole`): a runner gives the workspace, profile,
   limits and environment; an adapter gives only the program and its arguments.
4. The model-free scripted adapter and its program (`scripts/runner/scripted-role`), usable for honest and
   hostile roles alike.

## 2. Decisions

| # | Decision |
|---|---|
| A1 | **Answers.** Kinds `discovery` (Planner), `candidate` (Planner), `challenge` (challenger), `implementation` (Implementer), `review` (Reviewer), each an exact JSON object (fields as in `Roles.hs`); unknown keys, wrong types, unknown kinds, trailing text: `malformed-output <reason>`. |
| A2 | **Rules** (pure, `checkAnswer`; first failing rule). Text 1–4000 characters, not blank, no control but new line and tab; ids `[a-z][a-z0-9-]{0,39}`; paths per C-P4.4 G1; citations: valid path, 1 ≤ first ≤ last, at most 201 lines; checks: argv 1–64 entries, each ≤ 4096, no NUL, non-empty program; signature 1–200 printable ASCII. Discovery: `summary-invalid`, `citations-invalid` (1–50), `reproduction-invalid`, `paths-invalid` (1–50, no repeats). Candidate: `criteria-invalid` (1–30, unique ids, text and Ticket quote, 1–20 citations each), `paths-invalid`, `verification-invalid` (1–10 commands), `tests-invalid` (1–20, unique paths, content ≤ 256 KiB without NUL), `red-without-signature`, `tests-overlap-allowed` (a test path among the allowed implementation paths). Challenge: `findings-invalid` (≤ 20), per finding `requirement-invalid`, `claim-invalid`, `basis-invalid` (1–20), `mutant-invalid` (≤ 10 files, unique valid paths), `demonstration-invalid`, `test-invalid`. Implementation `summary-invalid`. Review `reasons-invalid` (1–20). The role that was asked must answer (`wrong-kind`). Words inside an answer are kept as text and never acted on. |
| A3 | **Context.** The role's input is `context.json`, an exact JSON document (`Lockstep.Foundation.Json`, keys in order, RFC 8259 escaping); what it holds per role is the engine's (P4.6 onward). |
| A4 | **Scripted adapter.** Copies the fixed program `scripts/runner/scripted-role` and the invocation's script into the input; argv `python3 <input>/scripted-role <input>/script.json <tree> <output>` in the runner's view. The program's steps: write, append, delete, symlink, chmod, mkdir, result, result_raw, stdout (repeat), stderr, sleep, linger, connect, run, env, read, exit; a failing step is reported and the script goes on. |
| A5 | **Invocation.** `invokeRole runner adapter role workspace context protected`: writes `context.json`; the Implementer runs with the `run-write` profile, every other role read-only; limits `roleLimits` (C-P4.2 R1); then: runner uncertain → `RoleUncertain` (never re-run by itself); runner refusal → `runner-refused <code>`; `Exited 0` → the answer file (a regular file, not a link: `output-not-a-file`; ≤ 256 KiB: `output-too-large`; absent: `output-missing`) decoded (A1) and checked (A2: `answer-invalid <code>`); `Exited 75` → `provider-refused` (quota, rate limit or refusal by the provider); other exits `role-crashed`; `role-timed-out`, `role-output-limit`, `role-output-held`, `role-cancelled`, `role-launch-failed`. The run's evidence (streams, counts, time) is kept with every outcome that has one. |
| A6 | **Runners.** `helperRunner channel` (the container, C-P4.2 R3/R4; workspace view `/work/tree`, `/input`, `/output`; no result or an interrupted run → uncertain) and `directRunner cancel root` (C-P4.2 R2; host paths; best-effort read-only tree and protected files, **no boundary**). A family's adapter cannot choose the profile, limits, mounts, network or runner. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/RolesTest.hs` | unit | A1 decoding of every kind; 12 malformed forms; A2 every rule and `wrong-kind`; injected instructions kept as text, a path out of the tree refused; A3 exact JSON |
| `test/integration/Lockstep/RolesTest.hs` | integration, real processes | A4/A5 with the real program on the direct runner: an honest answer and its context; missing, linked, oversized, malformed, wrong-kind answers; crash, provider refusal, timeout, flood; cancellation; the Implementer's tree; a widening answer refused; uncertain and refused runners |

## 3a. Not built here

| Item | Status | Why |
|---|---|---|
| Claude Code CLI adapter (`Lockstep.Effects.Provider.Live`) | NOT_BUILT | needs the owner's separate live authorization (DG-17); the guard (`check-guard` (c)) already reserves the module; the A5 interface takes it unchanged |

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before role invocation was implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RolesTest.hs` | `bf0c720e014cc333861de2e831ec9dd04d1d56b018dea90863c7592e54ef2f89` |
| `test/integration/Lockstep/RolesTest.hs` | `42e6d492509d6864f64d0c0134a74be4088a93d83751824c7ba38830d1c6ab3a` |
| `test/unit/Main.hs` (runner, additive) | `ed57bd96990bd667f62937e049ac73eede9f63d9bbe310c0a31af3753b90a3bd` |
| `test/integration/Main.hs` (runner, additive) | `0a965f348ee874d6a1fb099fb5b54ece18f7d4c09314d4b90461fbeb98c5439c` |

Pre-freeze verification (logs in this directory):

- Written before the freeze: the answer rules (`Lockstep.Kernel.Roles`), the JSON documents
  (`Lockstep.Foundation.Json`), strict answer decoding (`decodeAnswer`), the two runners and the scripted
  adapter (thin wrappers of C-P4.2). The invocation path (`invokeRole`, `prepareRole`, `runPrepared`) was a stub
  refusing `not-implemented`; the scripted-role program is in place. Build (purity scan, 28 files), format and
  lint clean (2 hints fixed; two test paths changed from an `.ssh` example the forbidden-facilities scan refuses).
- Unit (`prefreeze-unit.log`): 845 of 845, the 9 new cases on the real pure code.
- Integration baseline against the stub (`prefreeze-integration-baseline.log`): **7 of 7 fail**, each at its
  first invocation (`not-implemented`).
- Fixture trial against the draft invocation path (`fixture-trial.log`): **7 of 7 passed**, so no assertion
  needed correcting; the stub was put back for this freeze commit.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Roles.hs`, `src/Lockstep/Foundation/Json.hs`, `src/Lockstep/Effects/Roles.hs`,
`scripts/runner/scripted-role`, the two test files. Changed: `lockstep.cabal` (generated), the runners
(additive), `docs/gates/P4.5/**`, `docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the P4.5 commits.
