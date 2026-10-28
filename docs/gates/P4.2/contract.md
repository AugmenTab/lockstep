# Contract — P4.2 Finite confined subprocess runner

- Contract ID: `C-P4.2@v1`
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.2 ("the controlled direct-argv process runner with process-group
  supervision, output capture, timeouts, cancellation, descendant termination and restricted
  environment/credentials … real processes with deliberately excessive output, a hanging descendant,
  cancellation, failure, malformed arguments and attempted out-of-scope effects. Exit: external processes
  are bounded and cannot acquire unrestricted host mutation authority"); **DG-17 ACCEPTED** 2026-10-28
  (D-17.1(a) container per invocation launched by the authenticated host helper; pinned image, non-root,
  read-only root, dropped capabilities, bounded processes and resources, no privileged Docker access;
  `run-role` by explicit allowlist; `--network none`; no home, SSH, keychain, Docker socket or credentials;
  D-17.7 limits; D-17.9 argv only); DR-P3.1/DG-15 (the helper: signed, versioned, allowlisted, serialized,
  durable results); C-P3.1 §4 (the channel form); C-P2.6 X2 (an uncertain outcome is not a failure);
  `engine-design.md` §2.
- Writer: the single writing agent (Implementer, manual).
- Scope: the runner layer only. No role, prompt, provider, Git change or engine stage uses it yet (P4.4
  onward). No live provider; no change to the operator's installation.

## 1. What P4.2 delivers

1. **Pure run rules** (`Lockstep.Kernel.Runner`): a run is an argument vector, an absolute directory, an
   explicit environment and finite limits; checked before anything starts. The DG-17 limits table and the
   fixed run environment.
2. **The direct runner** (`Lockstep.Effects.Process.runDirect`): one local process group, bounded and
   cancellable; for model-free roles, deterministic commands and the test suite. It is *not* a filesystem or
   network boundary and says so.
3. **The container runner** in the host helper (`scripts/control-helper --runner`): a second, separately keyed
   channel; each run a new container from a fixed table; one run at a time; signed results.
4. **The service's client** (`Lockstep.Foundation.RunnerProtocol`, `Lockstep.Effects.HelperRunner`), and
   `scripts/service` mounting the runner channel when the helper names it.

## 2. Decisions

| # | Decision |
|---|---|
| R1 | **Rules** (pure). `checkSpec`, first failing rule wins: `argv-empty`; `argv-invalid` (empty program, > 1024 entries, an entry > 32768 characters or with NUL, > 262144 characters in all); `executable-not-absolute` (contains `/`, does not start with it); `directory-invalid` (not absolute, NUL, a `..` segment); `environment-invalid` (> 64 entries, name not `[A-Za-z_][A-Za-z0-9_]{0,127}`, repeated name, value > 32768 or with NUL); `limits-invalid` (wall 1–3600000 ms, each stream 0–67108864 bytes). `roleLimits`: Implementer 1200000 ms, every other role and command 600000 ms; stdout 8 MiB, stderr 2 MiB. `runnerEnvironment home` = PATH `/usr/local/bin:/usr/bin:/bin`, HOME, LANG and LC_ALL `C.UTF-8`, TZ `UTC`, nothing else. Outcomes: `Exited n`, `TimedOut`, `OutputLimit stream`, `OutputHeld stream`, `Cancelled`, `LaunchFailed`; **only `Exited 0` succeeds**. |
| R2 | **Direct runner.** Refuses with an R1 code, `directory-missing` or `executable-missing` (a bare name is looked up only in the run's own PATH) before starting anything. Then: no shell; exactly the given environment; standard input `/dev/null`; no inherited descriptors (`close_fds`); a new process group. Ends at the first of exit, wall clock (`timed-out`), a stream past its limit (`output-limit`, the first *limit* bytes kept, the observed count reported), or cancellation (`cancelled`). Whatever ends it, processes still in the group get TERM, then KILL after 2 s; a group still alive after the program exited is reported (`descendants killed`). A stream still held open 2 s after that (a process that left the group) is `output-held`. An asynchronous exception in the caller kills the group. |
| R3 | **Container runner** (helper, enabled only by `--runner`; without it the helper is unchanged). `DIR/runner/` (0700): `channel.key` (made by the helper, 0600, separate from the pane's key), `requests/`, `results/`, `work/<run>/` (`tree/`, `input/`, `output/`, `argv` NUL-separated, optional `protected`). Request `.rreq`, seven printable lines (`lockstep-runner-request 1`, `id`, `issued`, `op run-readonly\|run-write\|run-verify\|cancel-run`, `expect run-<32 hex>`, `argv <SHA-256 of the argv file>\|none`, `mac`), ≤ 1024 bytes, HMAC-SHA256 under the runner key, within 120 s, never replayed. Refusals, nothing run: `bad-mac`, `malformed`, `stale`, `unknown-op`, `bad-expect`, `run-missing` (not a real directory of this user, or a symlink), `argv-missing`, `argv-too-large`, `argv-mismatch`, `argv-malformed`, `protected-invalid` (not `[A-Za-z0-9._+@-][A-Za-z0-9._+@/-]*`, an empty, `.` or `..` segment, a symlink on the way, not a regular file), `runner-image-missing`, `busy` (one run at a time). The run: `docker run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --pids-limit 256 --memory 4g --memory-swap 4g --cpus 2 --user <uid:gid> --log-driver none`, environment HOME=/tmp and the R1 variables, the tree at `/work/tree` (read-only unless `run-write`), `input` read-only, `output` writable, each protected file read-only over the tree, the image pinned by ID at helper start (`LOCKSTEP_RUNNER_IMAGE`, default `lockstep-dev:p1`). Limits from a fixed table (`run-write` 1200 s, others 600 s; 8 MiB / 2 MiB); `LOCKSTEP_RUNNER_TEST_LIMITS=1` at helper start (the host check only) makes them 6 s, 64 KiB, 16 KiB. Outcomes `exited` (with the exit code), `timed-out`, `output-limit`, `cancelled`, `launch-failed` (Docker's 125); the container is always removed. The result carries the exit code, run, image ID, byte counts, SHA-256 of both streams and the limits. A run started but not ended when the helper restarts gets `interrupted`. `cancel-run` stops the active run. |
| R4 | **Client.** `openRunnerChannel` (`runner-unavailable` if there is no key); `prepareRun` makes a new run directory; `submitRun` checks the argv (R1) and protected paths before writing anything, writes the files, signs the request, waits; maps the result: `refused` → `HelperRefused reason`; `interrupted` → `HelperInterrupted`; no result in time → `HelperNoResult` (both **unknown outcomes**: the caller must not re-run by itself); a stream whose bytes do not match the signed digest → `HelperResultInvalid output-digest`. `scripts/service` mounts `LOCKSTEP_SERVICE_RUNNER` (set by the helper with `--runner`) at its own path and passes `LOCKSTEP_RUNNER_DIR`; nothing else changes. |
| R5 | **Not here.** Which runner a role uses, the role protocols, snapshots, Git and the live provider are later sub-phases. The launcher (`./lockstep`) does not yet pass `--runner`; that is wired when the engine first runs a role (P4.10 at the latest), so the installed product is unchanged by P4.2. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/RunnerTest.hs` | unit | R1: acceptance, every refusal and its order, inclusive bounds, the limits table, the environment, outcomes |
| `test/unit/Lockstep/Foundation/RunnerProtocolTest.hs` | unit | R3/R4: the exact request bytes and MAC (independent vector), result decoding and a changed byte refused, `interpretResult` (digests, refused, interrupted, stream of an output limit) |
| `test/integration/Lockstep/ProcessRunnerTest.hs` | integration, real processes | R2: exit and streams; too much stdout and stderr; wall clock with a sleeping descendant gone; a lingering descendant killed; cancellation; failures and a killed program; 16 refusals with nothing started; the exact environment; empty input and descriptors 0–2 only; bare names in the run's PATH |
| `test/integration/Lockstep/HelperRunnerTest.hs` | integration, the real helper with a `docker` stand-in | R3/R4 end to end: a signed run and its streams; a helper refusal with nothing run; cancellation; no helper → unknown outcome; client-side refusals with nothing sent |
| `scripts/lib/check-runner` | host check (Docker, real containers) | R3: signed result and pinned image; no network (only `lo`, no outside connection); read-only root; no Docker socket or home; non-root, no capabilities, no new privileges; no host variable (a canary); read-only tree for read-only roles, writable for `run-write`, no `.git`; protected files unwritable and unremovable; ≤ 256 processes; wall clock (timed-out, container gone); output limit (exact kept size, container gone); cancellation and `busy`; refusals (MAC, stale, op, missing and symlinked run, argv digest, `..` and symlinked protected paths, a non-hex run); replay runs nothing |

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the runners were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RunnerTest.hs` | `9d33c8fa68c71a8e758b61d04593a6b66bf1fd95d4dfc349f66993064463a605` |
| `test/unit/Lockstep/Foundation/RunnerProtocolTest.hs` | `e110a50f5e843f3351989a6e8c5beaa911957e26b15c7cc4b703b24578f2225b` |
| `test/integration/Lockstep/ProcessRunnerTest.hs` | `af9dc2bd9c5d013a9c17c86108e16bca794540e09d6642ab2a38a16ff4331ecc` |
| `test/integration/Lockstep/HelperRunnerTest.hs` | `7049247c7ee30f0d482c1073cbdcf606549147c77c8e7314fdc476ffe06b3225` |
| `scripts/lib/check-runner` (host check) | `20f710cc4fbc05bbd79c2de382441a61e71acd0e8aef4520fe3203f7b40779fe` |
| `test/unit/Main.hs` (runner, additive) | `6220a054b67962a594e4a460570bc98494cd9a49bf94c61c19d9c2db165798d1` |
| `test/integration/Main.hs` (runner, additive) | `0250cd91ebcd52082877187a73741f376a2b4afa1d3d5035119c23dc48782e14` |

Pre-freeze verification (logs in this directory):

- The pure rules (`Lockstep.Kernel.Runner`) and the channel forms (`Lockstep.Foundation.RunnerProtocol`) were
  written before the freeze; `runDirect` was a stub refusing `not-implemented`; the client's
  `openRunnerChannel` a stub that never opens a channel (`interpretResult`, pure, was written); the helper and
  `scripts/service` unchanged. Build (Kernel boundary and purity scan), format (run last, on every frozen
  file: nothing changed) and lint clean.
- Unit (`prefreeze-unit.log`): 831 of 831, the 13 new cases on the real pure code. The result MAC vector was
  first computed over a body whose trailing space (`detail \n`, as the helper writes it) had been lost in the
  scratch file; recomputed over the exact bytes (`openssl dgst -sha256 -mac HMAC`) before the freeze.
- Integration baseline (`prefreeze-integration-baseline.log`), targeted to the two C-P4.2 groups: **16 of 16
  fail**, each at the missing feature: the 11 direct-runner cases at `not-implemented` (the refusal case
  shows all 16 codes as `not-implemented`), the 3 helper cases at "the helper did not make the runner key"
  (the helper refuses `--runner`), the 2 client cases at `not-implemented`. Each fails at its first call;
  every later assertion was checked against R1–R4 by reading.
- Host check baseline (`prefreeze-check-runner.log`): the helper refuses `--runner` (usage), nothing ran.
- The Simple Haskell audit of the same day (`docs/reviews/simple-haskell-audit-2026-10-28.md`) found two
  `fromJust` in `RunnerProtocolTest`; replaced before the freeze (hlint would have failed).

## 5. Allowed paths

New: `src/Lockstep/Kernel/Runner.hs`, `src/Lockstep/Effects/Process.hs`,
`src/Lockstep/Foundation/RunnerProtocol.hs`, `src/Lockstep/Effects/HelperRunner.hs`, the test files above.
Changed: `scripts/control-helper` (the runner channel, behind `--runner`), `scripts/service` (the runner
mount), `lockstep.cabal` (generated), the runners (additive), `docs/gates/P4.2/**`,
`docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-17 or a
frozen test. Rollback: revert the P4.2 commits; nothing is migrated.
