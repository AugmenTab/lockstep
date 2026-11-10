# Dev Capsules: VM-backed execution (Phase 5)

- **Status:** P5.1 deliverable, written by the single writing agent (Implementer) on `phase-5`. Not accepted.
- **Authority:** `.local/plans/phase-05.md` (the owner's Phase 5 handoff, 2026-11-09).
- **Basis:** `remediation/type-discipline` at `cb22f2c`, the latest tested revision (unit 870/870, integration
  571/571, compliance 93/93 per `.local/retros/retro-04_update10.md`). `git log --all` shows no later commit. The
  working tree was clean. `phase-5` branches from it.
- **Companion records:** contracts `docs/gates/VM-1/contract.md` (C-P5.1, C-P5.2 and later), evidence
  `docs/gates/VM-1/qualification.md`, the threat model in §11 here.

## 0. What changes, and what does not

Phase 4 ran every role, and every deterministic proof step, in containers on the host's Docker. The role container
held the authenticated CLI *and* ran the repository's code; the runner container had one generic toolchain and no
network. That model cannot build a real project (`docs/gates/brigid-dogfood/environment-blocker.md`, B1–B8).

Phase 5 moves **all untrusted execution into a per-project Linux VM, the Dev Capsule**. The provider CLI stays on
the host side, in its existing container, and **keeps no built-in tool at all**. Its only tools are a Lockstep MCP
server, the *capsule bridge*. Each bridged call is executed in the capsule by the deterministic *Capsule Runtime*.

Unchanged: the Supervisor's sole authority over work state, scheduling, roles, frozen tests, Git and human
decisions; the role workflow (Planner → freeze with challenge → one Implementer → deterministic verification →
post-work challenge → Reviewer → Supervisor commit → human Done); native subscription authentication (C-P4.L.N);
the egress filter; one writer per repository.

## 1. Trust boundaries

```text
 TRUSTED (host)                                               | UNTRUSTED
                                                              |
 Lockstep service + Supervisor (Haskell, PostgreSQL)          |
   decides: which role, which capsule, which transaction      |
        | signed runner requests (existing channel)           |
 control-helper (bash, host user)                             |
   starts the provider container; binds each invocation       |
        |                                                     |
 Capsule Runtime  scripts/capsule-runtime (bash, host user)   |
   lifecycle: provision/start/stop/inspect/snapshot/          |
              restore/destroy/import/run (allowlisted)        |
   serve: one invocation's channel, bound by its record ----------> limactl shell (SSH) --> Dev Capsule VM
        ^ files: requests/N.json, results/N.json              |       guest-exec: read, list, search,
        |                                                     |       write, edit, exec
 provider container  lockstep-provider:claude-2.1.312         |       workspace /work/repo, caches,
   CLI (uid 2000000000, not dumpable), --tools ""             |       guest Docker Engine + Compose,
   capsule-bridge (MCP stdio, the CLI's only tool source)     |       guest root: the Engineer's own
   auth volume (the CLI's own token), egress filter           |
```

| Boundary | What crosses it | What may not |
|---|---|---|
| B1 Supervisor ⇄ helpers | HMAC-signed requests with fixed vocabularies (existing). | Free text to a host shell. |
| B2 Capsule Runtime ⇄ VM | Fixed argv (`limactl shell … /opt/lockstep/guest-exec …`), the request on stdin. | Host mounts, sockets, agent forwarding, port forwarding (§7). |
| B3 Provider container ⇄ Runtime | Request and result files in the invocation's channel directory. | A capsule name, project or role (these come from the binding, §6). |
| B4 Provider container ⇄ VM | Nothing directly. No network path and no shared file. | The auth volume, the CLI's memory or environment, the egress filter. |
| B5 Guest ⇄ host network | Public package downloads (policy §7). | Host services, the host Docker socket, other capsules (§7, measured in P5.4). |
| B6 Candidate ⇄ verification | A validated content snapshot of the candidate tree (§8). | The candidate's own test runner, hooks, logs or Git metadata as authority. |

## 2. Guest VM lifecycle

States as the runtime reports them: `absent` → `creating` (record written, VM being created) → `ready` + `Running`
⇄ `Stopped` → `destroyed` (disposable capsules only). Lima's own status (`Running`, `Stopped`, `Broken`) is read back
on every operation and never cached as truth.

- **provision** is idempotent. A record for the same project with a ready VM returns `already=yes`. A record for
  another project is refused. A half-done provision (record `phase creating`) resumes and does not start over.
- **start/stop** are idempotent (`already=yes`).
- **destroy** works only on a capsule provisioned `disposable`. The owner's working capsules are never destroyed by
  Lockstep.
- A session ending does not touch the capsule (§9).

## 3. Workspace and disk ownership

- One VM disk per capsule (Lima `diffdisk`, VZ), under the runtime's own `LIMA_HOME`
  (`<state>/capsules/lima`), never `~/.lima`. Lockstep cannot see or touch the owner's other VMs.
- The project lives at `/work/repo` on the VM disk. It is a **clone imported from a Git bundle** that the Supervisor
  makes from the canonical repository at the transaction's basis (`import`). The owner's checkout is never mounted.
- Caches (`~/.stack`, `~/.cargo`, `~/.npm`, Docker images and volumes) live on the same disk and persist across
  sessions, stops and host reboots.
- Snapshots (§8) are APFS clones (`cp -c`) of the stopped VM's disk, so they are cheap and complete. Lima's own
  `snapshot` command is QEMU-only.

## 4. Provisioning and configuration format

- The only VM configuration is `scripts/capsule/lima-capsule.yaml`. Upstream Lima templates are not used: the
  default template mounts the host home, and the docker template forwards the guest's Docker socket to the host.
- The runtime substitutes only three numbers from a fixed **profile** (`small` 2 CPU / 4 GiB / 30 GiB / 30 min a
  command; `standard` 4 / 8 / 60 / 60 min; `large` 6 / 12 / 100 / 120 min). Nothing a caller supplies reaches the
  YAML.
- Before every start, the runtime audits the effective configuration Lima stored: byte-equal to the record's copy,
  `mounts: []`, `forwardAgent: false`, `vmType: vz`, no socket forwarding. Any drift refuses the start.
- Guest setup (cloud-init provision script): Docker Engine, Compose v2, buildx, git, build-essential, python3, jq,
  `/work`. Project toolchains are installed **by the Engineer inside the guest** as normal development work (apt,
  ghcup, Stack, rustup, npm, …). No host-maintained toolchain list exists.

## 5. Provider execution boundary

**Decision (P5.1, measured in §10):** the CLI runs in the existing provider container, as before: two identities,
the CLI not dumpable, the auth volume, the egress filter. It runs with **`--tools ""`**, so it has no built-in Bash,
Read, Edit or any other tool. It also runs with `--strict-mcp-config --mcp-config <the capsule bridge>`, so the
bridge is its only tool source, and with `--setting-sources user` (agent-entry), so no repository settings apply.

Consequences:

- No model-directed operation can run in the credential-bearing container. There is no tool to run it, and no
  fallback, because the CLI has no other tool.
- The provider container mounts **no project tree at all**. Repository-local `.claude/` settings, `.mcp.json`,
  `CLAUDE.md` and hooks are not present where the CLI runs, so they cannot alter its tool routing.
- Guest code runs on another machine, the VM. It shares no kernel, process table, filesystem or network with the
  provider container. So it cannot read the CLI's memory, its descriptors, the auth volume or the token.
- Role inputs (`role.md`, the context) are given to the CLI in its prompt and input mount. They are not files the
  model must open with a local Read.

Rejected alternative: installing an authenticated CLI inside the guest. Guest root, or guest Docker, would own its
token.

## 6. Guest tool execution protocol

**Binding.** For each live invocation, the Supervisor's helper asks the runtime to `bind INVOCATION CAPSULE PROJECT
TRANSACTION ROLE LIMIT`. The runtime checks that the capsule's record names the project, derives the allowed
operations from the role, refuses a second live implementer for the project, and makes the invocation's channel.
The channel directory is the only thing mounted into the provider container (`/bridge`). `serve INVOCATION` answers
that channel and nothing else.

| Role | Operations |
|---|---|
| implementer | `read`, `list`, `search`, `write`, `edit`, `exec` |
| planner, challenger, reviewer | `read`, `list`, `search` (no command: guest sudo or Docker would make any command mutating in the Engineer's VM; a separate review capsule is future work) |

**The channel.** `requests/` is mounted read-write into the provider's container. `results/` is mounted
**read-only**, so only the runtime writes a result. The runtime moves each request into the invocation's private
directory **before** checking it. One `serve` per invocation (a PID lock). Bindings for a project are made under
that project's lock.

**Request** (written by the bridge, trusted code in the provider container):
`{"v": 1, "seq": N, "op": OP, "args": {...}}` as `requests/N.json`. The runtime reads only the fixed-format prefix
(version, sequence equal to the file name, operation). It checks the operation against the **binding**, not the
bridge, and pipes the file to `guest-exec --op OP` in the VM. guest-exec refuses a request whose operation
differs, or one with duplicate keys. The arguments never reach a host command line.

**Result** `results/N.json`. Line 1 is the runtime's own envelope (trusted): `host_outcome` is `completed`,
`refused`, `timed-out`, `cancelled`, `output-limit`, `capsule-unavailable` or `effect-unknown`, with a detail.
Line 2 is the guest's answer (untrusted data): status, exit code, stdout, stderr, truncation and elapsed time. The
bridge shows the model the exit status, stdout and stderr as they are. A failed command is never made to look
successful.

**Limits.** A per-command deadline (the binding's limit, at most the profile's), enforced twice: `guest-exec`
kills the command's process group, and the runtime's watchdog (limit + 30 s) ends the call and cancels it in the
guest. Output: 1 MiB per stream in the guest, 4 MiB total at the host. Cancellation: the CLI's
`notifications/cancelled` → `requests/N.cancel` → `guest-exec --cancel N` (the process group).

**Fail closed.** If the runtime does not answer within the bridge's wait limit, the call fails as "did not answer
(outcome unknown)". Nothing runs anywhere else.

## 7. Network and host isolation

- **No shared files:** `mounts: []`. **No forwarded sockets:** neither the guest's Docker socket nor any host
  socket. **No SSH agent, no X11.** **No port forwarding:** all guest ports are ignored in both directions of Lima's
  forwarder.
- **The guest's Docker daemon is the guest's.** The host Docker socket is never reachable (P5.4 negative test).
- **Host services.** Lima's user-mode network gives the guest a gateway to the host (`host.lima.internal`,
  192.168.5.2). Whether host-loopback services (PostgreSQL, the Lockstep service, the control pane) are reachable
  through it is measured in P5.4. The guest's own firewall does not count, because guest root controls it. If they
  are reachable, the boundary must be enforced outside the guest, or the gap escalated
  (handoff §19: "the VM cannot be isolated from protected host services").
- **Public egress** is allowed so the Engineer can download packages. It is not yet constrained or recorded per
  destination; see the limitations in `docs/gates/VM-1/qualification.md`.

## 8. Snapshots and verification

| Snapshot | Taken | Owner | Use |
|---|---|---|---|
| `base` | after provision + environment setup | runtime | known-good environment; rebuild point |
| `work` | on demand | runtime | the Engineer's mutable state before a risky step |
| `frozen-tests` | at freeze | Supervisor | the frozen-test basis |
| `candidate` | Implementer done | Supervisor | the candidate implementation state |
| `verify` | per verification | Supervisor | disposable verification environment |

**Verification is not the Implementer's VM saying "green".** The Supervisor's plan for P5.7:

1. The candidate is collected as **content**: a tree of regular files from the capsule, validated by path, type and
   size, never as the guest's `.git`.
2. The verification capsule is a separate disposable VM restored from the trusted `base` snapshot. It is never the
   Implementer's live VM, so no lingering Implementer process can run during verification.
3. The Supervisor overlays the frozen test files from its own canonical frozen commit, plus the project's declared
   check command from the Contract. The candidate's copies of those paths are discarded.
4. The check runs through `run` with the Supervisor's own script. Its exit status is the runtime's own observation.
   Logs the candidate wrote are never read as results.

## 9. Supervisor Git integration

- The canonical repository stays on the host, owned by the Supervisor (unchanged). The capsule's `/work/repo` is a
  clone for development. Its commits, branches, remotes, hooks and config are the Engineer's scratch, with no
  authority.
- **Acceptance** (P5.8): the Supervisor builds a trusted temporary repository from the verified basis, writes the
  validated candidate content into it, and commits with fixed Git options: `core.hooksPath=/dev/null`, no fsmonitor,
  no filters, no attributes from the guest, and only regular files under allowed paths. It then advances the work
  branch by compare-and-swap, as in Phase 4. Host Git never runs inside a guest-controlled `.git`.
- Nothing is pushed. The guest has no host Git credentials.

## 10. Recovery and ambiguous effects

- Every bridged call is journalled `start` and `end` in the invocation's `ledger` and the runtime journal. The
  request is held as `req.N` while it runs.
- A runtime restart finds each `req.N` that never ended and answers it `effect-unknown executor-restarted`. **It is
  never replayed.** A VM that stopped during a call gives `effect-unknown vm-stopped-during-call`.
- Lifecycle operations are idempotent and journalled. A provision interrupted at `phase creating` resumes.
- The capsule outlives sessions. Only an operator or a `disposable` test destroys it.
- Retry classes (C-P5.9):

  | Class | Meaning | Handling |
  |---|---|---|
  | `refused` | nothing ran | safe to correct and retry |
  | `capsule-unavailable` | nothing ran | start the VM, then retry |
  | `completed` with a lost response | done | reconciled from the ledger |
  | `effect-unknown` | may or may not have run | never replayed automatically |
  | `timed-out` or `cancelled` | ended by Lockstep | the Engineer decides what to re-run |

## 11. Threat model (summary)

| # | Adversary | Goal | Defence |
|---|---|---|---|
| A1 | Guest code (repository, dependencies, containers), guest root | read the provider token | the token is in another machine's container (B4) |
| A2 | Guest code | run on the host, reach the host Docker socket or host files | VM boundary; no mounts, sockets or forwarding (§7); audited config |
| A3 | Guest code | reach host services or other capsules | §7; measured in P5.4; escalation if not enforceable outside the guest |
| A4 | Model (prompt-injected) | run a command in the provider container | no built-in tools; no fallback (§5, T6, T9) |
| A5 | Model or bridge | address another capsule or project | the binding names the capsule, not the request (T11) |
| A6 | Model in a read-only role | write | the binding's operations; the host refuses forged ops (T10) |
| A7 | Implementer | redefine success (edit frozen tests, runners, logs, Git) | §8 verification from trusted content; §9 Git reconstruction |
| A8 | Second writer | write concurrently | one live implementer binding per project (T12); the engine's single writer |
| A9 | Crash or restart | replay an effect blindly | §10 |

## 12. Typed operations (Haskell side)

`Lockstep.Kernel.Capsule` gives the Supervisor the same vocabulary as typed values: `CapsuleId`, `ProjectId`,
`CapsuleInvocationId`, `CapsuleRole`, `CapsuleOperation` (the operation per role), `CapsuleState`,
`CapsuleProfile`, `HostOutcome` and `CapsuleRefusal`. Each has one encoder and one decoder, matching the runtime's
words. The runtime's bash allowlist and these types are checked against each other by tests.
