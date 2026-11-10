# Contract — Phase 5 Dev Capsules (Gate VM-1)

- Contract IDs: `C-P5.1@v1` (architecture, tool routing, typed vocabulary), `C-P5.2@v1` (VM lifecycle),
  `C-P5.3@v1` (workspace and snapshots), `C-P5.4@v1` (guest Docker and development freedom). Later subphases
  (P5.5–P5.12) are added here as they are reached.
- Status: **CANDIDATE**, written by the single writing agent (Implementer). Not accepted; Gate VM-1 is the owner's.
- Authority: `.local/plans/phase-05.md` (the owner's Phase 5 handoff, 2026-11-09). Design:
  `docs/architecture/dev-capsules.md`.
- Basis: `remediation/type-discipline` at `cb22f2c`, verified as the latest tested revision, clean tree. Branch `phase-5`.

## 0. Baseline classification (handoff §1.2)

| Item | Phase 5 safety or execution? | Disposition |
|---|---|---|
| Increment E M2 (Orb handler contracts; one-module-per-route layout) | No: web-layer typing only | stays deferred to V3 |
| Increment E M3 (typed `hx-` attributes, client JS) | No: browser layer only | stays deferred to V3 |
| Increment F, the `Text` inventory | No | not folded into Phase 5 (handoff §17.4) |
| The two recurring frozen-test races (`LifecycleHelperTest` service-stop, `ReconciliationTest` lease) | No: both pass on re-run; owner items | unchanged; reported if seen |

## 1. C-P5.1 Tool routing and the typed vocabulary

**Decision R1.** The provider CLI runs in its existing container with **no built-in tools** (`--tools ""`). Its
only tool source is the capsule bridge (`scripts/runner/provider/capsule-bridge`, MCP over stdio,
`--strict-mcp-config`). Each call is executed by the Capsule Runtime (`scripts/capsule-runtime serve`) in the
capsule that the invocation's binding names.

| # | Requirement | Check |
|---|---|---|
| T1 | `exec` runs in the capsule. It returns that machine's output, the exit status and stderr separately. | `check-capsule-bridge` |
| T2 | `write` and `edit` change files in the capsule. `edit` replaces exactly one occurrence. | ″ |
| T3 | `read` (numbered lines), `search` and `list` work in the capsule. | ″ |
| T4 | Multi-line shell, pipes, subshells and redirects run unrestricted. No command syntax is refused. | ″ |
| T5 | A command over its time limit is reported `timed-out` and ended (it writes nothing afterwards). | ″, `check-capsule-vm` B2 |
| T6 | The CLI has no built-in Bash. A model call to it is refused by the CLI, and nothing runs in the provider container. | ″ |
| T7 | A model-directed command sees neither the provider's auth volume, its channel, nor its environment. | ″ |
| T8 | A full scripted session completes (exit 0, JSON result). | ″ |
| T9 | With no executor serving, a call fails closed ("did not answer", outcome unknown). Nothing runs in the capsule or the provider container. | ″ |
| T10 | A read-only role is offered no write tool. The host refuses a forged `write` or `exec` in its channel (`op-not-authorized-for-role`). | ″ |
| T11 | A binding for a capsule of another project, or with an invalid capsule id, is refused. | ″ |
| T12 | A second live implementer binding for the same project is refused (`writer-already-active`). | ″ |
| T13 | A request that smuggles a second operation (a duplicate key) is refused by the guest; nothing happens. | ″ (review finding 6) |
| T14 | A request file that is a symlink to a host file is refused as not regular; the host file goes nowhere. | ″ (finding 2) |
| T15 | A second server for the same invocation is refused (`already-serving`). | ″ (finding 7) |
| V1 | Each runtime enumeration has one text, parsed back by derivation. | `lockstep-capsule` |
| V2 | Capsule names are validated. The VM name is derived, never given. | ″ |
| V3 | Only the Implementer has mutating operations, and only it runs commands. The runtime's binding grants exactly `roleOperations`. | ″ |
| V4 | Every refusal, outcome, operation and profile in the Kernel is the runtime script's own word. | ″ |

Safety of the checks: the upstream is the stand-in `scripts/lib/live-standin-secret` on an internal Docker
network. The key is synthetic (`sk-ant-test-…`). No provider is contacted. **These are not evidence of a real
subscription session.**

The bridge check uses the runtime's **fixture backend**, a network-less container standing in for the guest. It
answers the question of *where model-directed operations execute*. The VM itself is qualified by
`check-capsule-vm`.

## 2. C-P5.2 VM lifecycle (Lima, VZ)

| # | Requirement | Check (`scripts/lib/check-capsule-vm`) |
|---|---|---|
| L1 | Invalid capsule or project ids are refused before use. | L1 lines |
| L2 | First provision and startup; idempotent repeat (`already=yes`, one VM); inspect; stop and start; a different project refused; no take-over. | L2 lines |
| L3 | Shell text in a lifecycle parameter is refused and never run. | L3 |
| L4 | The effective Lima configuration is audited before each start: byte-equal to the record, `mounts: []`, no agent forwarding, VZ, no forwarded sockets. | inspect `audit=ok` |
| L5 | Finite named resource profiles (small, standard, large). Actual values are recorded. | provision line, resources note |
| L6 | Only a capsule provisioned `disposable` can be destroyed. | destroy line |

## 3. C-P5.3 Workspace and snapshots

| # | Requirement | Check |
|---|---|---|
| W1 | The project enters as a Git bundle imported into `/work/tree` on the VM disk (the one workspace path: import, bridged calls and capsule-mode runs), at its revision. The source side is unchanged. | W1 lines |
| W2 | Build artifacts, the guest Docker cache, pulled images and installed packages persist across a VM restart. A warm check passes. | W2 lines |
| W3 | No host directory is mounted, so a guest symlink has no host target. | D2 lines |
| W4 | A whole-disk snapshot (APFS clone of the stopped VM's disk) restores later changes and deletions. A snapshot name with a path is refused. | W4 lines |
| W5 | Restoring a missing snapshot is refused, leaving no partial state. | W5 |

Cross-capsule storage isolation follows from one disk per VM with no shared mount. A two-capsule test is P5.11's.

## 4. C-P5.4 Guest Docker and development freedom

| # | Requirement | Check |
|---|---|---|
| D1 | The guest's Docker daemon is its own, not the host's Docker Desktop. | D1 |
| D2 | No host directory is mounted. `/Users` is not visible. | D2 |
| D3 | No SSH agent is forwarded. | D3 |
| D4 | A host-loopback service is not reachable from the guest (probed via `host.lima.internal` and 192.168.5.2). | D4 |
| D5 | A project-defined `scripts/test` builds a C program, builds a Docker image and runs a Compose service in the guest. | D5 lines |
| D6 | Scripts, functions, pipes, subshells and interpreters run. The Engineer installs an OS package itself. | D6 lines |
| D7 | A full disk refuses writes visibly. The capsule and its Docker recover once space is freed. | D7 lines |
| B1–B3 | Bridged `exec` against the VM: the guest user's groups, the time limit, cancellation, no surviving process. | B lines |
| R2 | A call in flight when the executor stops is answered `effect-unknown executor-restarted` and never replayed. | R2 |

## 4a. C-P5.5–C-P5.7 The helper's capsule mode (`scripts/capsule/helper-capsule.sh`)

The Supervisor's runner requests are unchanged. Capsule mode (an owner-made `DIR/capsule/config`) changes only
where they run. The service learns of it from `DIR/runner/capsule` and uses the capsule adapter, which runs
`claude` with `--tools ""` and the capsule tools' instructions.

| # | Requirement | Check (`scripts/lib/check-capsule-runner`) |
|---|---|---|
| A0 | Capsule mode is on only with a valid config and an audited, running capsule; the service is told. | A0 |
| A1 | A writing run executes in the Engineer's capsule. Its tree returns as regular files and directories only. Ignored build output stays in the guest. Protected files are the Supervisor's own, and a guest change to them is reported. | A1 |
| A2 | A read-only run's writes never return. The project's real failure is reported. | A2 |
| A3 | With no verification capsule, `run-verify` is refused (`verification-environment-missing`), never run in the Engineer's VM. | A3 |
| V1 | Verification runs in a separate VM, restored from its trusted `verify` snapshot before every run. | B0, B2 |
| V2 | An Implementer that fakes its own toolchain cannot fake verification. | B1, B2 |
| V3 | A verification run that tampers with its VM (a fake tool, a lingering process) does not affect the next. | B3, B4 |
| V4 | RED and GREEN are genuine: the buggy tree fails and the fixed tree passes, for the real reason. | B2, B4, B5 |
| L1 | A live argv that keeps any built-in tool, or names its own MCP configuration, is refused before anything runs. | C1 |
| L2 | A live Implementer reads its instructions, edits, builds and tests in the capsule, and answers. The answer and tree come back. No built-in Bash. No credential or provider variable in the capsule. Usage is in tokens. The token is in no kept file. | C2 |
| L3 | A live read-only role reads and answers (`answer` writes only `/output/result.json`). It has no write or exec tool, and nothing it attempted reaches the tree. | C3 |

## 5. Test-first record

- `check-capsule-bridge`: written together with the bridge and the runtime as the P5.1 feasibility spike (handoff
  §5 calls for a spike). Its first run failed 20 of 29 checks (`evidence/p5.1-bridge/first-run-red.log`): the
  runtime lacked its `serve` dispatch, and macOS has no `timeout`. After those two fixes all 29 passed. This RED
  came from a defect, not from a pre-implementation freeze, and is recorded as such.
- `lockstep-capsule`: written with `Lockstep.Kernel.Capsule`. 18/18.
- `check-capsule-vm`: frozen in the P5.1 commit, before its first run against a real VM.
