# P1.7 Contract — Reproducible qualification and Gate A

- Contract ID: `C-P1.7@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `15ad3f2`. P1.1/P1.2 ACCEPTED; P1.3–P1.6 `VERIFIED — awaiting human acceptance`.
- Authority: `.local/plans/phase-01.md` §P1.7 and operating rule 4; the owner's instruction of
  2026-10-18 ("Continue into P1.6 and P1.7 if all required checks pass … Present their existing
  evidence for human acceptance with Gate A"). Design contracts: `docs/TESTING_STRATEGY.md` §6, §8,
  §11; `docs/architecture/ARCHITECTURE.md` §4 step 5; `docs/VISUAL_EVIDENCE_CONTRACT.md` §2–§7;
  ADR-0002 (database operations). No open decision gate applies.
- Traces: FR-APP-01…05, FR-APP-09 (primitive); NFR-04/07/08/09/11/12/13/14; PRD scenario A1
  ("clean build, migration, secure DB-backed status, durable command receipt").
- Writer: the single writing agent (manual; no v2 Supervisor). **Gate A is decided only by the
  human owner**, against an exact report revision and digest.

## 1. Objective

Finish `scripts/check` (step 5, the no-live-model guard), make the service installable and
operable from this host with documented procedures, run scenario A1 end to end against the
installed service, and produce `docs/gates/A/gate-report.md` with per-criterion evidence and an
honest machine summary. Phase 2 does not start.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Supported provider CLIs** for the sentinel: `claude`, `codex` (Bible v2.1: Claude/Codex accounts; TESTING_STRATEGY §8). The list lives in `scripts/lib/provider-clis` (one name per line). |
| E2 | **Sentinel shims (TESTING_STRATEGY §8.2).** Before step 4, `scripts/check` creates `.local/check-sentinel/<run>/bin/<cli>` for each CLI: a shell script that appends `<cli> <args>` to `$LOCKSTEP_SENTINEL_LOG` and exits 97, and an empty `sentinel.log`. Steps 4 and 6 run with `LOCKSTEP_SENTINEL_DIR` set; `scripts/lib/check-step` then prefixes `PATH` with the shim directory and exports `LOCKSTEP_SENTINEL_LOG`. The unit step keeps `--network none`; the integration step keeps its private network. |
| E3 | **Step 5 `guard`** (`scripts/lib/check-step guard`, then `scripts/lib/check-guard`), in order, each failing the step: (a) every listed CLI resolves (`command -v`) to its shim, else **FAILED** (never skipped); (b) sentinel negative test: after asserting `claude` resolves to the shim, it runs `claude --probe` with a separate probe log and requires exit 97 and exactly one probe entry; if `claude` resolves anywhere else it aborts without executing and reports NOT_RUN, which fails the step; (c) construction check: no file in `src/`, `app/`, `test/` imports `Lockstep.Effects.Provider.Live` except that module itself, `app/lockstep/Main.hs` and `app/lockstep-smoke/` (the module does not exist yet; the check still runs and reports the scanned file count); (d) fault-plan refusal: the built `lockstep` binary run with `LOCKSTEP_FAULT_PLAN=FP-CMD-AFTER-ADMIT` for `serve`, `db status` and `workspace show` must exit **78** with the E4 message and print nothing on stdout; (e) the main sentinel log is empty. After step 6, `scripts/check` re-runs (e); a non-empty log then marks step 5 FAILED. |
| E4 | **Fault plans are refused by every build.** No `fault-injection` flag exists yet (fault points arrive at P2.8). If `LOCKSTEP_FAULT_PLAN` is set (any value), every `lockstep` command exits 78 before reading arguments, configuration or the database, with stderr `lockstep: fault plans are not accepted by this build (no fault-injection flag)`. |
| E5 | **Guard self-test** (`scripts/lib/check-guard-selftest`, run inside step 5): proves each mechanism can fail: a missing shim, a shim shadowed by another `claude` earlier on `PATH`, a non-empty sentinel log, a forbidden `Provider.Live` import in a temporary file, and a fake binary that accepts a fault plan each make `check-guard` fail. |
| E6 | **Installed service** (`scripts/service`): `install` builds the release binary from the current checkout in the dev container (`stack install --local-bin-path .local/install/bin`) and records the commit, dirty flag and SHA-256 in `.local/install/VERSION`; `start [--port N]` runs it detached in a container named `lockstep-service` with **`--network host`**, mounting only `.local/install` (read-only) and a generated config `.local/config/lockstep-host.json` (0600; host `127.0.0.1`, port 5433) — no repository files, no static directory, no Node/Python; `stop` sends SIGTERM and waits up to 10 s; `restart`; `status`; `logs`; `cli <args>` runs the same installed binary with the same config (e.g. `scripts/service cli operator sign-in`). The binary still binds `127.0.0.1` only; Docker Desktop host networking makes that listener reachable at the Mac's `127.0.0.1:<port>` (verified 2026-10-18), so no non-loopback listener exists. |
| E7 | **Operator guide** `docs/OPERATOR_GUIDE.md`: prerequisites; fresh clone and container build; `scripts/db up/status/backup/restore/down`; `lockstep db migrate` and the backup rule; `scripts/service install/start/stop/restart/status/logs/cli`; sign-in and sign-out; workspace and job commands; the command center; clean restart; troubleshooting (a service started before migration runs no dispatcher until restarted; `localhost` is refused; a fault plan is refused); where evidence lives. |
| E8 | **A1 scripted run** (`scripts/a1`, evidence under `docs/gates/A/evidence/a1/`): from a fresh clone of the tested commit: `scripts/check --integration`; `scripts/service install`; a **fresh database** `lockstep_a1_<UTC stamp>` on the operator PostgreSQL server; `db migrate`; readiness `ready 5`; `scripts/service start` with sentinel shims on the service's `PATH`; CLI sign-in and browser-shaped sign-in (curl with the exact `Origin`); a typed command via the HTTP form **and** via the CLI; duplicate (same key) → same receipt; stale → `refused_stale`; unauthorized (no session, wrong CSRF, foreign `Origin`, `Host: localhost`) → 401/403; a queued job admitted by a client that disconnects; `scripts/service restart`; after restart the same receipts, job outcome and command-center evidence are shown (headless Chromium screenshots through the cookie proxy, labelled); zero sentinel entries; the A1 database is kept for inspection and named in the report. Every command is recorded with argv, exit code and output digest (TESTING_STRATEGY §11). |
| E9 | **Human-operated demonstration** (TESTING_STRATEGY §2.1): the gate report lists the exact steps for the owner to operate A1 in their own browser against the installed service. Its row stays **NOT_RUN** until the owner performs it; the agent never fills it in. |
| E10 | **Gate A report** `docs/gates/A/gate-report.md` (VISUAL_EVIDENCE_CONTRACT §3–§7): header with repository, branch, tested commit, clean flag, schema revision, policy identity `manual — no v2 Supervisor`, and the governing document digests from `SOURCE_REGISTER.md`; one row per criterion `AC-A1-NN@v1` (statement, source refs, required, method, expected, actual, disposition, evidence locator + SHA-256); the sub-phase status table (P1.1/P1.2 ACCEPTED; P1.3–P1.7 awaiting the owner, with their tested commits and records); an honest machine summary = worst required effective disposition (it is `NOT_RUN` while E9 is pending), labelled "not acceptance"; known issues and limitations; and a decision block that only the owner fills in. A short decision packet `docs/gates/A/decision-packet.md` links the canonical artifacts. |
| E11 | **Independent read-only review**: a separate read-only reviewer agent (no write tools, same model family; disclosed as such, not a human review) checks the actual diffs, regression risks and missing gate proof; its findings and the writer's dispositions are recorded in `docs/gates/A/review.md`. |

## 3. Allowed paths

`app/lockstep/Main.hs`; `src/**` (E4 only); `scripts/check` (additive: shim setup, step 5,
post-integration log check — steps 1–4 and 6 unchanged); `scripts/lib/check-step` (additive:
`guard` step and the `LOCKSTEP_SENTINEL_DIR` prefix); new `scripts/lib/check-guard`,
`scripts/lib/check-guard-selftest`, `scripts/lib/provider-clis`, `scripts/service`, `scripts/a1`;
`test/integration/**` (new files only, plus the runner addition in §8); `README.md`,
`docs/OPERATOR_GUIDE.md`, `docs/gates/P1.7/**`, `docs/gates/A/**`, `.gitignore` if needed.
Not allowed without a stop: frozen tests, Henforcer configs, `.hlint.yaml`,
`scripts/lib/check-forbidden-facilities`, `stack.yaml*`, `Dockerfile`.

## 4. Production API the tests bind to

The `lockstep` executable's behaviour under `LOCKSTEP_FAULT_PLAN` (E4). No Haskell API.

## 5. Tests

| Kind | Case |
|---|---|
| Integration (frozen) `FaultPlanTest` | with `LOCKSTEP_FAULT_PLAN` set: `serve --port P`, `db status`, `workspace show`, `operator sign-in` and an invalid command line each exit 78 with the E4 stderr and empty stdout; `serve` never listens on `P`; with the variable unset, `serve` answers health as before |
| Static / script (step 5) | E3 (a)–(e) and the E5 self-test, run by every `scripts/check` |
| Scenario (A1) | E8, evidence in `docs/gates/A/evidence/a1/` |

## 6. Verification

Pre-freeze: the candidate integration test compiles and is **run** against the current binary;
its failures must be only the missing E4 behaviour. Acceptance: `scripts/check --integration`
from a fresh clone (step 5 PASSED, not NOT_RUN) and the Linux clone; frozen digests for P1.1–P1.7;
licenses; A1 evidence; the review record.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a behaviour that makes a frozen
expectation impossible, a path outside §3, a new dependency, or a design question §2 does not
settle. Rollback: revert the P1.7 commits; `scripts/service stop`; the A1 database can be dropped.

## 8. Freeze record

Frozen 2026-10-18 by the writing agent (manual; no v2 Supervisor).

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/FaultPlanTest.hs` | `44e779b9cdf589c497686bf56e0bfbb8146d9462d3ac6eadab36cb37f653cf85` |
| `test/integration/Main.hs` (runner, additive: 2 lines) | `97adf89b97293fd2c498d4c6465f89d747f54c1911774cbae0a888950ffcdcdd` |

Pre-freeze run (`evidence/prefreeze-integration-against-current-binary.log`): the suite compiles
under `--pedantic` and the unchanged Henforcer configs; run against the current binary, 63 tests
pass and 3 fail, all on the missing E4 behaviour (`serve` keeps running instead of exiting 78;
`db status` exits 66 instead of 78). The control case (no fault plan) passes.
