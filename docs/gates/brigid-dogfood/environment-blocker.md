# Brigid dogfood: Phase 4's runner cannot serve real projects. Decision request: move to Phase 5

- **For:** the Planner and the owner.
- **Prepared:** 2026-11-01 by the Implementer (manual), under the Brigid handoff §4: "document the exact blocker
  rather than weakening confinement."
- **Owner's position (2026-11-01):** this is not a "smallest fix" problem but a "Lockstep is entirely impractical to
  use" problem. Per-project execution environments were the intent of Phase 5, and "we will likely move to Phase 5."
- **Status: the dogfood STOPPED before registration.**
  - Nothing was installed, built, registered or run. There were no live model sessions and no tokens were spent.
  - The owner's clone `/Users/tab/personal/brigid` was only inspected (`git status`, `git log`): `main` at `331dcc0`,
    clean, even with `origin/main`. It was not modified.
  - Phase 5 has **not** been started. Starting it is the Planner's and the owner's decision.

## 1. Finding

Phase 4's execution model checks every project inside **one generic, sealed runner container that Lockstep owns**. Real
projects are not built that way. Each one carries its own environment: its own container, toolchain, dependency cache,
network needs and build times. Brigid's `scripts/test` expects Brigid's containerized environment, and Lockstep cannot
provide it.

The calculator smoke passed only because it was plain Python and both Lockstep images ship `python3`. Brigid is the
first real project and the first non-Python toolchain, and it fails before any test runs. So does any compiled language
or any project with a dependency cache (Stack, Cabal, Cargo, npm, Gradle, …). This is a property of the design, not a
Brigid quirk. Phase 4 accepted it explicitly in D-17.9: "a project whose toolchain is not in the image is refused as
`verification-environment-missing` (a later decision can add per-project images)".

## 2. Evidence: why the Phase 4 runner cannot run Brigid

All deterministic proof steps go through `execute_run` (`scripts/control-helper:1422-1492`). Those steps are
reproduction, baseline RED, verification GREEN, the mutant check and the counterexample check.

| # | Phase 4 constraint (source) | Effect on a Stack/GHC project |
|---|---|---|
| B1 | Fixed `PATH=/usr/local/bin:/usr/bin:/bin`; the run uses the host uid (`control-helper:1435-1436`) | GHC 9.10.3 and Stack 3.7.1 live under `/root/.ghcup/bin` (`Dockerfile:9-15`), which is off PATH and unreadable by that uid. The result is exit 127 and a `verification-environment-missing` halt. |
| B2 | `--network none` (`control-helper:1431`; D-17.4) | No dependency fetch. |
| B3 | No Stack root mounted; `--read-only` root filesystem | `STACK_ROOT=/stack-root` (`Dockerfile:69`) is empty in the image, and Stack needs it writable. |
| B4 | Tree mounted read-only except for `run-write` (`control-helper:1429-1430`) | Verification cannot write `.stack-work`. |
| B5 | The only writable scratch is a 256 MiB `/tmp` (`control-helper:1432`) | Too small for a Stack root plus build products. |
| B6 | 600 s, 4 GiB, 2 CPUs per verify run (`control-helper:1185-1188, 1434`) | A real build's limits differ by project. |
| B7 | One global runner image, pinned at helper start (`control-helper:1125, 1214`) | There is no per-project environment. |
| B8 | The live roles run in `lockstep-provider:claude-2.1.312`: `git` and `python3` only (`scripts/runner/provider/Dockerfile:34-42`) | The Engineer cannot build or test what it writes. |

Patching these one by one (custom images, scratch volumes, per-project limits) would make every new language or build
tool a new confinement exception. That approach does not scale, so I don't recommend it.

## 3. What a practical execution model needs (the Phase 5 intent)

Each role should run **inside the project's own development environment**, with the isolation boundary drawn around
that whole environment, such as a disposable per-Engineer VM, instead of around one locked-down container. Inside the
boundary:

- The project's environment runs as the project defines it: its own container or Compose setup, toolchain and scripts.
  Brigid's `scripts/test` runs unmodified. Docker inside a disposable VM is not the host Docker socket.
- Dependency caches persist across runs of the same project, so warm builds are fast.
- The network policy belongs to the environment, not to a single container. One illustrative split: dependency fetch
  allowed while preparing the environment, and role runs restricted. The Planner sets the actual policy.
- The Engineer can build and run tests itself, so it does not write fixes blind.
- Resource and time limits are set per project.

Outside the boundary, Lockstep keeps what makes it trustworthy: Supervisor-only Git, frozen tests whose integrity is
checked, deterministic verification, provider sign-in that never passes the token through Lockstep, and the human Done.

## 4. What Phase 4 established that carries forward

These held up on a real subscription in the calculator smoke (`docs/gates/P4.L.N/smoke-completion-packet.md`) and do
not depend on the runner's container model:

- The transaction workflow end to end: discovery, Contract and candidate tests, RED baseline, pre-freeze challenge,
  freeze, a single Implementer with retries, verification, post-fix challenge, review, Supervisor commit and human Done.
  It also resumed correctly after a helper restart.
- Supervisor-controlled Git: work branch only, compare-and-swap, `main` untouched, nothing pushed.
- Frozen-test protection, and deterministic proof steps that cost no tokens.
- Native subscription auth: the unmodified CLI holds its own token, and calls run over end-to-end TLS through a
  passthrough filter with an explicit host allowlist.
- The evidence record (`lockstep_invocations`) is authoritative and reconcilable.

What does not carry forward unchanged is `execute_run` and its per-run container contract (C-P4.2), the single global
runner image, and the toolchain-free provider image as the place where roles execute.

## 5. Decisions requested

1. **Planner/owner:** accept this finding, and **close the Brigid dogfood as BLOCKED BY DESIGN** under Phase 4 rather
   than as a Brigid or operator failure.
2. **Planner/owner:** authorize **Phase 5**, the per-Engineer environment, with Brigid as its acceptance target: the
   same bug ticket and the same handoff §7/§8 evidence, run through Lockstep inside Brigid's own environment.
3. **Planner:** say which deferred items (Brigid handoff §9; the role-count scrutiny; the token breakdown and cost
   monitor; the Orville/Fleece correction pass; UX-C8/C9) are in or out of Phase 5.
4. **Owner (operational):** for Phase 5 work, grant this session read access to the Brigid clone
   (`/add-dir /Users/tab/personal/brigid`) or provide a working clone under `~/lockstep-projects/brigid`. Lockstep makes
   work branches in place, so the owner's clone itself should never be registered.

## 6. Backlog findings recorded (not acted on)

- Dogfood earlier against a real compiled-language project. Offline qualification and a Python smoke could not
  surface this.
- The helper should detect a moved runner image instead of failing with 125 (carried from the smoke).
- Per-run token breakdown and a per-transaction cost monitor (carried from the smoke).
