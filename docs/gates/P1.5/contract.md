# P1.5 Contract — Persistent background service and dispatcher skeleton

- Contract ID: `C-P1.5@v1`
- Status: **FROZEN** (2026-10-17)
- Basis: `v2` at `04c3ff2`. P1.3 and P1.4 `VERIFIED — awaiting human
  acceptance`.
- Authority: `.local/plans/phase-01.md` §P1.5 and operating rule 4; the owner's continuation of
  2026-10-17. **Boundary with DG-04** (event, claim, outbox, replay and reconciliation protocol;
  owner decision, must settle by P2.5, prerequisites P1.7 and P2.2): this Contract does **not**
  decide DG-04. Its claim/lease/resume rules apply only to the model-free no-op job kind, which
  has no external effect, and are recorded as provisional skeleton behaviour for DG-04 to
  replace or confirm. No kind with an external effect may reuse them without DG-04.
- Traces: FR-APP-04 ("no web handler may own a long-running agent transaction"; "close HTTP
  connection and see command remain durably accepted"), NFR-08 ("service survives browser
  closure; queued…"); Plan v0.2 P1.5.
- Writer: the single writing agent (manual; no v2 Supervisor).

## 1. Objective

Admission and execution are separate. CLI and HTTP **admit** a typed command that queues a
model-free no-op job and return its receipt at once; only the running `lockstep serve` process
**executes** jobs, in a background dispatcher. Closing the browser, dropping the HTTP request or
restarting the service never loses or duplicates accepted work.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Command.** `OperatorCommand` gains `QueueNoop NoopSpec`, `NoopSpec { noopSteps :: 1–20, noopStepMillis :: 0–5000, noopFailAtStep :: Maybe (1–steps) }` (validated: `StepsOutOfRange`, `StepMillisOutOfRange`, `FailAtOutOfRange`). Same envelope, key, digest and `decide` as C-P1.4; payload text `steps=<n>;step_ms=<m>;fail_at=<k\|none>`, kind `queue-noop`. The expected revision is checked against the workspace revision (stale → `refused_stale` receipt) but queueing does **not** change the workspace: `decide` returns `Apply current` for this kind. |
| E2 | **Admission.** In the C-P1.4 transaction, an applied `queue-noop` inserts a receipt with outcome **`queued`** and one job row referencing it. A replay returns the same receipt; no second job. The admission transaction never waits for execution. |
| E3 | **Migration `0004`.** Widens the receipt outcome check to `('applied', 'refused_stale', 'queued')` and creates `lockstep_jobs(id bigint identity PK, receipt_id bigint NOT NULL UNIQUE REFERENCES lockstep_command_receipts(id), kind text NOT NULL CHECK (kind = 'noop'), state text NOT NULL CHECK (state IN ('queued', 'running', 'succeeded', 'failed')), steps_total integer NOT NULL, step_millis integer NOT NULL, fail_at_step integer, steps_done integer NOT NULL DEFAULT 0, attempts integer NOT NULL DEFAULT 0, owner text, lease_until timestamptz, created_at timestamptz NOT NULL DEFAULT now(), started_at timestamptz, finished_at timestamptz, last_error text, recovered_count integer NOT NULL DEFAULT 0)`. |
| E4 | **Dispatcher.** `serve` starts one background dispatcher thread when the database is `Ready`. Every 200 ms it claims at most one job: `queued`, or `running` with `lease_until < now()` (a crashed owner), oldest first, `FOR UPDATE SKIP LOCKED`, setting `state = 'running'`, `owner` = a random per-process id, `lease_until = now() + (step_millis + 5000) ms` (amended, §9 A2), `attempts + 1`, `started_at` if null, and `recovered_count + 1` when it was `running`. Then for each step from `steps_done + 1`: if the step equals `fail_at_step`, set `failed` with `last_error = 'deterministic failure injected at step <k>'` and stop; otherwise sleep `step_millis`, then set `steps_done = step` and renew the lease, **only while `owner` is still this process** (a lost lease stops the run). After the last step: `succeeded`. Each update is its own short transaction. |
| E5 | **Shutdown and recovery.** On SIGTERM the dispatcher stops between steps and returns its running job to `queued` (`owner`, `lease_until` cleared), so a restart resumes it at once from `steps_done`. After a crash (no release) the job is reclaimed when its lease expires and resumes from `steps_done`. A no-op step has no effect outside the job row, so re-running an interrupted step is safe; this is the only reason resume is allowed (see the DG-04 boundary above). A dispatcher error is logged as a fixed line with the job id and does not stop `serve`. |
| E6 | **CLI.** `lockstep job queue --expected-revision N [--steps S] [--step-ms M] [--fail-at-step K] [--idempotency-key K]` (defaults: 3 steps, 100 ms, no failure) prints `receipt <id> queued revision <n> key <k> job <j>` (+ ` (replayed)`); refusals as C-P1.4 E8. `lockstep job show J` prints `job <j> <state> steps <done>/<total> attempts <a>` and, if failed, a second line `error: <last_error>`; unknown → exit 65. The CLI never executes a job. |
| E7 | **HTTP.** `POST /operator/commands/queue-noop` (fields `steps`, `step_ms`, `fail_at_step` (empty = none), `expected_revision`, `idempotency_key`, `csrf`; guard, session and CSRF as before) → `303` to `/operator/receipts/<id>` for `queued`, other outcomes as C-P1.4 E9. It returns without waiting for the job. The receipt page shows the job's state, progress, attempts and error. The queue form is served at `GET /operator/jobs/new` (protected), linked from `/operator` (amended, §9 A1). |
| E8 | **Layering.** `Lockstep.Application.Command` (admission), `Lockstep.Application.Dispatcher` (the loop, using `Lockstep.Persistence.Jobs`), started from `Main.serve`. No new dependency; the thread uses `base`/`unliftio`. |

## 3. Allowed paths

As C-P1.4 §3, with `docs/gates/P1.5/**`. Frozen P1.1–P1.4 tests are not editable.
Out of scope: the command-center view (P1.6), any job kind with an external effect, a general
Supervisor or agent runtime.

## 4. Production API the tests bind to

```haskell
-- Lockstep.Application.Command (additions)
data NoopSpec = NoopSpec { noopSteps :: Int, noopStepMillis :: Int, noopFailAtStep :: Maybe Int }
mkNoopSpec :: Int -> Int -> Maybe Int -> Either InvalidReason NoopSpec
InvalidReason: ... | StepsOutOfRange | StepMillisOutOfRange | FailAtOutOfRange
OperatorCommand: ... | QueueNoop NoopSpec
Outcome: ... | Queued

-- Lockstep.Application.Dispatcher (not bound by the frozen tests, which observe jobs through the CLI and SQL)
data JobState = JobQueued | JobRunning | JobSucceeded | JobFailed
data Job = Job { jobId :: Int64, jobReceiptId :: Int64, jobState :: JobState, jobStepsDone :: Int, jobStepsTotal :: Int, jobAttempts :: Int, jobRecovered :: Int, jobError :: Maybe Text }
findJob :: DatabaseRuntime -> Int64 -> IO (Maybe Job)

-- Lockstep.Foundation.Cli (additions)
Command: ... | JobQueue QueueArgs | JobShow Integer
data QueueArgs = QueueArgs { queueExpected :: Integer, queueSteps :: Integer, queueStepMillis :: Integer, queueFailAt :: Maybe Integer, queueKey :: Maybe String }
CliError: ... | InvalidNumber String String   -- option or argument name, value
```

## 5. Tests

Unit: `NoopSpec` bounds; digest differs by each spec field and from a rename; `decide` returns
`Apply current` for a queue command and `RefuseStale` when stale; CLI parsing of `job queue` /
`job show` (defaults, `=` forms, missing expected revision, invalid numbers, unknown options,
missing/extra job id).

Integration (real PostgreSQL + the real binary):

| Case | Asserts |
|---|---|
| Queue while no service runs | CLI queue → `queued` receipt and job; after 1 s the job is still `queued`, `steps_done = 0` (the CLI executes nothing) |
| Service executes | start `serve` → the job reaches `succeeded`, `steps 3/3`, `attempts 1`; the workspace revision is unchanged |
| HTTP returns before the work | a 10 × 300 ms job queued over HTTP answers 303 within 1 s while the job is `queued` or `running`; it later succeeds |
| Disconnect | a raw HTTP queue POST whose client closes right after sending → the job is admitted and succeeds |
| Duplicate admission | the same key twice (CLI, then HTTP) → one receipt, one job |
| Deterministic failure | `--fail-at-step 2` of 3 → `failed`, `steps 1/3`, `error: deterministic failure injected at step 2`; not retried |
| Restart (SIGTERM) | stop `serve` mid-job → the job is `queued` with `steps_done` > 0; restart → it resumes from there and succeeds with `attempts 2` and no step lost |
| Crash (SIGKILL) | kill `serve` mid-job → the job stays `running`; restart → after the lease expires it is reclaimed (`recovered 1`) and succeeds |
| Two services | two `serve` processes on different ports, one database, three jobs → every job succeeds exactly once (`attempts 1` each without crashes) |
| Backup gate | revision 3 → `db migrate` without a flag → exit 75; `--no-backup` applies `0004` |

## 6–7. Verification, budget, stop, rollback

As C-P1.4 §6–§7 (fresh clone, Linux clone, digests, additive runners, licenses, operator run with a
backup before `0004`).

## 8. Freeze record

Frozen 2026-10-17 by the writing agent (manual; no v2 Supervisor). Frozen test files never
change in P1.5.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Application/NoopCommandTest.hs` | `bffb73a18b443d33b3a2a93d491076e24723920ba6201df8d697e5057adfd289` |
| `test/unit/Lockstep/Foundation/CliJobTest.hs` | `25115a612101e549ae2d3aec9e7084711fd40deb650e11726fb7b3441afd9cf3` |
| `test/integration/Lockstep/DispatcherTest.hs` | `b34935aa617aa6e6f95fdbb5f65da25182dc5990bf8a77687f01f754f7b1efd9` |
| `test/unit/Main.hs` (runner, additive) | `e9b5d9fadffb2ea187151439df4e98924c2460f0a40773b8f5b36411bf1f75e3` |
| `test/integration/Main.hs` (runner, additive) | `1f61addd5bf20f54fc0db3b25240876863f7eb929c1df000d3958e41a839af0b` |

Runner changes (named in advance, additive only): `test/unit/Main.hs` gains `NoopCommandTest`,
`CliJobTest` (4 added lines); `test/integration/Main.hs` gains `DispatcherTest` (2 added lines).
Frozen helpers reused unchanged; the dispatcher test starts `serve` itself because it needs
SIGKILL and two concurrent services, which `Support/Process.withService` does not offer.

Pre-freeze verification: type-only stubs (scratch, not committed: the `Command` additions,
`Lockstep.Application.Dispatcher`, the `Cli` additions) — both suites compile under
`--pedantic` and the unchanged Henforcer configs (`evidence/prefreeze-stub-build.log`);
fourmolu and lint clean; baseline against `04c3ff2` fails only on the missing exports
`NoopSpec(..)`, `mkNoopSpec`, `QueueArgs(..)` (`evidence/prefreeze-baseline.log`); the
integration suite compiles against the current code (it binds only to existing modules) and
fails at run time until the feature exists. Frozen backup-gate tests of P1.3/P1.4 expect
`applied migrations: 2` / `3` as substrings, which `…: 2, 3, 4` and `…: 3, 4` satisfy.

## 9. Amendments (human owner, 2026-10-18; `decision-request.md`, "Human decisions")

| # | Amendment | Authority |
|---|---|---|
| A1 | E7: the queue form is at `GET /operator/jobs/new`, linked from `/operator` (a second form on `/operator` would break the frozen P1.4 `fieldValue` helper, which requires one `idempotency_key` input). | "Queue-form placement RATIFIED." |
| A2 | E4: the lease is `now() + (step_millis + 5000) ms`, for the model-free no-op dispatcher only; it does not approve external-effect replay or pre-empt DG-04. | "Dispatcher lease RATIFIED." |
| A3 | **R-P1.5-1** test amendment and re-freeze, below. | "R-P1.5-1 APPROVED, conditional on …" |

### 9.1 R-P1.5-1 re-freeze

`test/integration/Lockstep/DispatcherTest.hs` amended with exactly
`evidence/proposed-test-fix.diff` (sha256 `d30e9d763d62f875f1a5af224f371dba3ceb7a74d194ed7b77240db14854edd8`):
`healthy` catches `HttpException` as "not ready yet"; `jobState` uses one query instead of four.
No assertion, timing or scenario change. Superseded digest `b34935aa…`; **new frozen digest**:

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/DispatcherTest.hs` | `2c1673f607829b0a65061b3283ed1a9dce888a9756cfa06dcf1bff1e97b0c457` |

The other §8 digests are unchanged.

### 9.2 Known issue (recorded at the owner's instruction, not fixed)

The frozen P1.2 helper `test/integration/Lockstep/Support/Postgres.hs` opens a new connection
pool for each `queryInts` / `queryBool` / `adminExecute` call and never closes it; connections
stay open for at least the 1 s linger time. Fast polling through it can exhaust PostgreSQL's
`max_connections` (100), which caused the P1.5 SIGKILL-case failure before A3. New tests should
poll with one query per iteration. Per the owner's instruction, the accepted P1.2 helper is not
refactored unless correctness requires it.
