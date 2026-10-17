# Lockstep v2 — Testing Strategy (design contract)

- Document: LS-V2-TEST-STRATEGY
- Status: **PROPOSED** design contract (P0.4). It is approved at Gate P0 as a
  contract, **not** as implemented behavior. It authorizes no model calls, UI
  acceptance or code writes.
- Revision: 0.1, 2026-10-16
- Traces: FR-EXE-12, NFR-09, NFR-13; PRD §10.1; Bible §3.6.5, §28.1; Plan §1.4, §14
- Implemented by: P1.7 (CI guard), P2.8 (model-free harness), P3.4 (scripted
  adapters), P3.6/P3.11 (false-green fixtures), P3.16 (C1–C3)

## 1. Principle

> Model inference is not the test harness. (Bible §3.6.5)

Every orchestration behavior is proven without a live model. Only the model's
probabilistic response is replaced, by a **scripted typed role adapter**. The
Supervisor, policy, PostgreSQL claims and outbox, process runner, Git
repositories and evidence projector stay **real** wherever a scenario claims to
prove them. A scripted result is never labeled as evidence of real-model quality.

## 2. Test strata

| Stratum | Suite | Proves | Real PG | Real Git/process | Live model |
|---|---|---|---|---|---|
| S1 Pure transitions / property / state-machine | `lockstep-unit` | Legal/illegal transitions, refusals, deterministic selection, totality | No | No | **Never** |
| S2 Scripted role-protocol scenarios + trace replay | `lockstep-integration` | Planner → Implementer → Reviewer → challenger orchestration, human interventions | Yes | Yes | **Never** |
| S3 Real-effect integration + fault injection | `lockstep-integration` | Transactions, claims, outbox, Git commits/worktrees, process groups, crash recovery | Yes | Yes | **Never** |
| S4 Provider adapter contract tests | `lockstep-unit` (stub CLIs) | argv construction, typed parsing, timeout, partial output, secret redaction | No | Stub executables | **Never** |
| S5 Live-provider smoke / quality evaluation | `lockstep-smoke` (separate, not built by default) | Credentials, transport, real model behavior | Optional | Yes | **Yes: opt-in, budgeted** (§9) |

S1–S4 make up the "ordinary tests" and CI. S5 is never part of `scripts/check`.

### 2.1 Required quality layers (PRD §10.1), by where they live

| Layer | Stratum / suite | First required |
|---|---|---|
| HTTP/operator tests: CSRF/origin refusal, stale POST, idempotent command receipt (same identity returns the same receipt), client disconnect, replay | S3 `lockstep-integration` (real Warp listener + PostgreSQL) | P1.3 (CSRF/origin), P1.4 (idempotency/stale), P1.5 (disconnect) |
| Projection re-derivation: every evidence or status view is recomputed from canonical DB rows and compared with what was rendered. Not-run or inconclusive must never render as passed. | S1 (pure `Evidence.Model`) + S3 (DB → rendered HTML assertions) | P1.6; expanded at P3.15, P4.8 |
| External adapter tests: duplicate, out-of-order, stale, revoked-authorization and uncertain-network events against stub remotes | S3 with local stub HTTP servers; never a real GitHub/Shortcut in CI | P6.3, P7.2 (out of P0–P3 scope) |
| End-to-end UI demonstrations | Scripted operator journeys against the real service and browser HTML (no live model), plus a **human-operated** demonstration recorded as evidence for Gates A and C | A1 at P1.7; C1–C3 at P3.16 (Plan Gate C: "a human operates UJ-01 through the supported UI") |
| Overnight qualification | S3 fault suites + authorized S5 | P10.5 |

## 3. Scripted typed role adapter contract

### 3.1 Role interface (conceptual Haskell; the final API is frozen at P3.4)

```haskell
data Role = Planner | Implementer | Reviewer | Challenger | Scribe

data RoleRequest = RoleRequest
  { invocationId    :: InvocationId     -- durable identity, minted before dispatch
  , role            :: Role
  , contractDigest  :: Maybe Digest
  , contextDigest   :: Digest           -- Context Pack digest
  , worktree        :: WorktreePath     -- authorized root
  , authorizedPaths :: [RelPath]        -- write ceiling (Implementer only)
  , limits          :: Limits           -- wall time, output bytes, turns
  }

data RoleOutcome                         -- every adapter (Scripted or Live) returns this
  = Completed  TypedPayload
  | Malformed  RawExcerpt ParseError     -- schema-invalid output
  | Partial    RawExcerpt                -- truncated / incomplete
  | Refused    Text                      -- model declined
  | QuotaExhausted ProviderSignal
  | TimedOut   Duration
  | Crashed    ExitInfo
```

The **same** `RoleOutcome` type flows from `Effects.Provider.Scripted` and
`Effects.Provider.Live`, so no Supervisor code path can tell them apart. The
adapter has no authority of its own. It returns an allegation that the
Supervisor validates (Bible §10).

### 3.2 Scripted adapter rules

1. It is driven only by a **fixture file**. An invocation that does not match a
   fixture step is a test failure (`UNSCRIPTED_INVOCATION`). It is never a
   fallback to anything live.
2. It may perform **real filesystem writes** in the worktree when the step says
   so. That simulates an Implementer editing files, so path-guard and Git
   checks act on real changes. Every scripted write is resolved inside a
   per-test **sandbox root** (a fresh temp directory containing the worktree).
   A path that escapes the root, whether by `..`, an absolute path or a symlink,
   is not written by the harness. It is handed to the Supervisor as a
   *requested* write, and the expected refusal is asserted. Malicious fixtures
   can therefore never touch the host.
3. It records each consumed step to the run's evidence. At the end of a
   scenario, any unconsumed step fails the test (`UNUSED_SCRIPT_STEP`), which
   catches orchestration that silently skips a role.
4. It is deterministic. Any delay uses the controlled clock (§6), never sleeps.

### 3.3 Fixture schema `lockstep.scripted-scenario/v1` (JSON)

A scenario is an ordered list of **steps**. A step is either a scripted
**role response** (consumed when the Supervisor invokes that role) or an
**injected input** that the harness delivers through the same typed boundary as
production (operator command, human answer, external event, clock advance).

| Step kind | Delivered via | Fields |
|---|---|---|
| `role` | Scripted adapter when invoked | `match {role, ordinal}`, `effects[]`, `outcome` |
| `operator_command` | Application command API (same as CLI/HTTP) | `command`, `args`, `expected_revision`, `idempotency_key` |
| `human_answer` | Human-request answer operation | `request_ref`, `request_revision`, `answer` |
| `external_event` | Event-ingress boundary (from P6) | `source`, `delivery_id`, `payload_file` |
| `advance_clock` | Controlled clock | `by_ms` |
| `fault` | Fault plan | `point`, `occurrence` |

```json
{
  "schema": "lockstep.scripted-scenario/v1",
  "scenario_id": "SCN-EXE-07-duplicate-answer",
  "description": "Implementer escalates; the human answers twice; exactly one continuation launches.",
  "traces": ["FR-EXE-07", "PY-REG-07"],
  "repo_seed": "fixtures/repos/minimal-hs",
  "steps": [
    { "kind": "role", "match": { "role": "Planner", "ordinal": 1 },
      "outcome": { "kind": "Completed", "payload_file": "planner-contract.json" } },
    { "kind": "role", "match": { "role": "Implementer", "ordinal": 1 },
      "outcome": { "kind": "Completed", "payload_file": "impl-blocked-human-required.json" } },
    { "kind": "human_answer", "request_ref": "HR-1", "request_revision": 1,
      "answer": { "choice": "proceed_with_option_a" } },
    { "kind": "human_answer", "request_ref": "HR-1", "request_revision": 1,
      "answer": { "choice": "proceed_with_option_b" } },
    { "kind": "role", "match": { "role": "Implementer", "ordinal": 2 },
      "effects": [ { "write_file": "src/Fix.hs", "content_file": "fix.hs" } ],
      "outcome": { "kind": "Completed", "payload_file": "impl-done.json" } }
  ],
  "expect": {
    "provider_invocations": { "Planner": 1, "Implementer": 2 },
    "refusals": [ { "step": 4, "kind": "HumanAnswerAlreadyRecorded" } ],
    "final_state": "VERIFYING"
  }
}
```

Fixtures live in `test/fixtures/scenarios/` and are versioned with the code. A
schema bump requires a migration of existing fixtures, never silent
reinterpretation.

### 3.4 Minimum fixture coverage (Bible §28.1)

These are required before Gate C: successful completion; schema-invalid,
malicious (path traversal or out-of-scope writes, injected instructions), and
partial outputs; timeout, cancellation and quota; stale and duplicated events
and human answers; unauthorized paths; immutable-test mutation attempts;
false-green semantic fixtures (pre-freeze and post-implementation);
crash-before/after-effect ambiguity; and recovery.

## 4. Deterministic inputs

| Input | Production | Test |
|---|---|---|
| Time | `Clock` capability → system clock | Controlled clock, advanced explicitly |
| Identifiers | UUIDv7/ULID generator capability | Seeded, sequential |
| Randomness | Capability | Fixed seed; property tests print the seed and replay it |
| Environment | Projected allowlist (Bible §24) | Same projection; asserted identical between preflight and invocation (PY-REG-09) |
| Locale / TZ | Explicit | `C.UTF-8`, `UTC` |

The Kernel receives time, ids and randomness as **values** (ARCHITECTURE §2).

## 5. Real PostgreSQL, Git and process qualification

- **PostgreSQL:** the integration suite starts from a fresh database per test
  module (template DB with migrations applied), against the same major version as
  production (proposed 15.x, as in Launchpad; DG-02 decides and is still OPEN). Tests cover migration up and the
  forward-recovery policy, concurrent claims across **separate connections**,
  stale revisions, and lost responses. In-memory substitutes are not acceptable
  evidence for Gate B (Plan §15).
- **Git:** real `git` in temporary repositories seeded from
  `test/fixtures/repos/`. Tests cover worktree creation, dirty-source refusal, ref
  collision, interrupted commit (fault point), and protected-test digest checks.
- **Processes:** real child processes launched as process groups, with timeout,
  kill, output caps and no-shell argv. A stub "provider CLI" (a tiny test
  executable) emits scripted bytes for S4.

## 6. Replayable events and observations; clock and fault injection

**Trace format `lockstep.trace/v1`:** an initial snapshot digest, then an ordered
list of `(observation, expected decision | expected refusal)`. A replay test feeds
the observations to the pure Kernel and asserts that the decisions are equal under
a **canonical encoding**: the versioned JSON form of `DomainEvent`/`EffectIntent`/
`Refusal`, with sorted keys, no floats and explicit schema versions. The encoding
is frozen with the Kernel types at P2.2. Golden traces may be *captured* from
S2/S3 runs, but a captured trace only becomes a golden fixture after a human
reviews it and its expected decisions against the Contract. Otherwise it would
just snapshot current behavior, bugs included. Golden traces are committed under
`test/fixtures/traces/`. A replay against an unknown trace version is refused,
never coerced.

**Fault points** (named and enumerated; extended per effect as it is added):

| Point | Window |
|---|---|
| `FP-CMD-AFTER-ADMIT` | command durably accepted, before HTTP response |
| `FP-CLAIM-BEFORE` / `FP-CLAIM-AFTER` | around the durable claim |
| `FP-EFFECT-BEFORE` / `FP-EFFECT-DURING` / `FP-EFFECT-AFTER` | around external effect execution, before the observation is persisted |
| `FP-OBS-PERSIST` | observation persisted, before the next decision |
| `FP-GIT-COMMIT-BEFORE-REF` | objects written, ref not updated |
| `FP-HUMAN-ANSWER-AFTER` | answer recorded, before continuation claim |

**Mechanism:** a `FaultPlan` capability that production wiring sets to
`noFaults`. Real crash tests run the `lockstep` binary as a subprocess with a fault
plan and kill it with SIGKILL at the point. The binary accepts a fault plan **only**
when built with the `fault-injection` Cabal flag. Because the test build carries
that flag, the refusal check runs in `scripts/check` against the **release build**
of `lockstep`: started with a fault plan, it must exit with a typed configuration
error.

## 7. Required case classes per behavior-changing Work Unit

| Class | Meaning | Minimum |
|---|---|---|
| Positive | The intended behavior happens | ≥ 1 |
| Negative | Invalid input is rejected with the correct typed error | ≥ 1 per input boundary |
| Refusal | Authority, staleness or policy violation produces a durable typed refusal (not an exception, not a UI-only message) | ≥ 1 per guarded transition |
| Recovery | Crash or uncertainty at each relevant fault point ends in a legal state with no duplicated effect | ≥ 1 per effect the Work Unit introduces |

A Contract that omits an applicable class must state why. The Reviewer checks this.

## 8. No-live-inference CI enforcement (by construction)

1. **No credentials:** the CI job runs with an empty, allowlisted environment.
   No provider tokens, and no `$HOME` with CLI auth state.
2. **Sentinel binaries, everywhere:** `scripts/check` itself, not only CI,
   creates a temporary bin directory of shims named after each supported provider
   CLI (`claude`, `codex`, …). It builds the test `PATH` as that directory plus
   the toolchain directories only, and passes it to the test suites. Each shim
   appends to `$LOCKSTEP_SENTINEL_LOG` and exits 97. Before running tests,
   `scripts/check` asserts that `command -v <cli>` resolves to the shim for every
   supported CLI. If any does not, the check **fails**. It is not skipped. Step 5
   fails if the log is non-empty. This holds on a developer host as well as in CI,
   so the step cannot pass vacuously.
3. **Network:** the unit suite runs with no network (`--network none` in the
   container). The integration suite gets only a private network containing PostgreSQL.
4. **Construction gate:** `Effects.Provider.Live` can only be constructed from a
   `LiveProviderConfig`. There are exactly two sources for one:
   (a) the operator's production provider configuration, loaded by the composition
   root for `lockstep serve` (ARCHITECTURE §2): configured accounts per FR-EXE-03,
   used for real Engineers and Gate C dogfood;
   (b) a smoke authorization file (§9), loaded only by `lockstep-smoke`.
   Test suites can construct neither. A static check in `scripts/check` fails if
   `Lockstep.Effects.Provider.Live` is imported anywhere except its own module,
   the composition root `app/lockstep/Main.hs`, and `app/lockstep-smoke/`.
5. **No fallback:** a provider adapter that is missing or misconfigured is a typed
   startup error. It never falls back to another provider or to an HTTP API
   (PRD FR-EXE-12).

Each mechanism gets its own **negative** test. The sentinel negative test (a
scripted run that deliberately execs `claude`) asserts **before acting** that
`claude` resolves to the shim. If it resolves anywhere else, the test aborts
without executing and reports `NOT_RUN`, never `PASSED`. It therefore cannot reach
a real CLI on any host.

## 9. Separately authorized, finite live-provider smoke tests

- Live tests live in `lockstep-smoke`, which is built only with
  `--flag lockstep:smoke`, and run via `scripts/smoke <authorization-file>`.
- The authorization file (`lockstep.live-authorization/v1`) must declare: the
  approving human, the adapter (CLI and version), the account/profile label (no
  secrets), the target (a disposable fixture repo only), max invocations, max
  turns, wall-time limit, a cost ceiling or `UNKNOWN`, an expiry date, and the
  scenario IDs.
- The runner refuses to start if any field is missing or expired. It stops at the
  first exceeded limit and records the outcome as `FAILED`, `BLOCKED` or
  `INCONCLUSIVE`. An unavailable provider is `NOT_RUN`, never `PASSED`.
- Evidence is labeled `LIVE` and kept separate from S1–S4 evidence. Gate C
  requires at least one authorized live smoke per supported adapter family
  (PRD §10.1).
- Known environment trap: on macOS, the Claude CLI needs `USER` in its
  environment for keychain auth. The projected environment must include it in
  both the probe and the invocation (PY-REG-09).

## 10. Python regression scenarios

Source: `docs/governance/PYTHON_REGRESSION_LESSONS.md`. Each lesson becomes a
versioned scenario when its subsystem lands. These are behavioral expectations,
not ports of Python tests.

| Scenario ID | Lesson | Stratum | Lands at |
|---|---|---|---|
| SCN-REG-01 | PY-REG-01 verification-environment prefix | S3 | P3.2/P3.10 |
| SCN-REG-02 | PY-REG-02 per-spec baseline classification | S2 | P3.7 |
| SCN-REG-03 | PY-REG-03 exact test targets, scope ceiling | S1+S3 | P3.7–P3.9 |
| SCN-REG-04 | PY-REG-04 future-code import correction, bounded | S2 | P3.7 |
| SCN-REG-05 | PY-REG-05 fixed-outline policy, no replan | S2 | P4.4/P4.5 |
| SCN-REG-06 | PY-REG-06 Planner-routed escalation in a full orchestrated run | S2 | P3.14 |
| SCN-REG-07 | PY-REG-07 durable human request, single continuation | S2+S3 | P3.14/P4.3 |
| SCN-REG-08 | PY-REG-08 at-most-once launch, crash windows | S3 | P2.6/P2.7, P3.16 |
| SCN-REG-09 | PY-REG-09 identical projected env probe/invoke | S4 | P3.4 |
| SCN-REG-10 | PY-REG-10 isolated verification cache | S3 | P3.10 |
| SCN-REG-11 | PY-REG-11 Planner on accepted basis only | S2 | P3.3/P3.7 |

## 11. Evidence and verification-command conventions

- **IDs:** test cases `<suite>/<Module>/<case>`; scenarios `SCN-<AREA>-<NN>`;
  acceptance criteria `AC-<SCOPE>-<NN>@v<rev>` (see VISUAL_EVIDENCE_CONTRACT §2).
- **Every verification command recorded as evidence** carries: argv (no shell
  string), cwd, environment *names* (never values), tool versions, tested Git
  revision plus a dirty flag, start/end time, exit code, and stdout/stderr SHA-256
  plus a locator. Output larger than the cap is truncated with a recorded
  truncation marker, never silently.
- **Gate commands** are written exactly as runnable from a clean checkout of the
  tested revision. Nothing depends on the operator's shell history or local state.
- A test that is skipped, filtered out or not built is reported `NOT_RUN`. The
  suite summary must list them.

## 12. Applicability by phase

| Item | P1.1 | P1.7 | P2.8 | P3.4+ |
|---|---|---|---|---|
| `scripts/check` steps 1–4 | required | required | required | required |
| Sentinel and no-network guard (§8) | — | **required** | required | required |
| Real PostgreSQL integration | — | (from P1.2) | required | required |
| Trace replay + fault points | — | — | **required** | required |
| Scripted role adapters | — | — | — | **required** |
| Live smoke | — | — | — | Gate C only, authorized |
