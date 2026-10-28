# DG-06, DG-07, DG-17 — decision request for Phase 4 (Gate C-EXEC)

- Prepared by: the writing agent (Implementer), 2026-10-27. **Nothing here is decided.** The human
  owner decides DG-06, DG-07 and DG-17 (`DECISION_REGISTER.md`: "Agents may prepare evidence and
  recommendations; they may not resolve a gate"). Status of all three: `EVIDENCE-PREPARED`.
- Why now: the Phase 4 handoff (`.local/plans/phase-04.md`, sha256 `24db39d9…f5698`) lists them as
  hard dependencies: **DG-17** for P4.2 (runner), P4.5 (provider adapters) and P4.10 (Implementer);
  **DG-07** for P4.7 (pre-freeze challenge) and P4.12; **DG-06** for P4.8 (Contract and candidate
  tests). The register forbids freezing a Contract against a gate that is not `ACCEPTED` (PRD §11.1).
  P4.1 (execution enablement, bug admission) and P4.3 (conversation core) do not depend on them and
  proceed meanwhile. Handoff §8: "document the exact competing options and the minimum decision
  required. Stop that unsafe path, not the entire project".
- Sources: Bible v2.2 §13.3, §31, §31.1 (Bug fix profile), insert 03; PRD v0.3 §4 (NFR-19,
  FR-AUX-01), §5 (C-EXEC scenario), §8 (DG-17 "concrete agent process confinement, provider CLI
  permissions, secrets separation, model family adapter and real Git boundary verification … a
  hard precondition to live consequential work"); Plan v0.3 §3 (DG-06/07/17 minimum requirements),
  §5; `docs/governance/PYTHON_REGRESSION_LESSONS.md` PY-REG-01…11 (what failed in the Python
  engine); DR-P3.1 / DG-15 (the host helper holds host authority; the service has no Docker
  socket); C-P3.5 J5 (added folders are mounted read-only; only the projects folder is writable).

## 0. Facts this request rests on (checked in the repository, 2026-10-27)

1. The service runs in a container (`scripts/service`): image `lockstep-dev:p1` (Debian with Git,
   Python 3, Chromium, the Haskell toolchain), `--network host`, as the host user, with project
   folders mounted at their own paths (the projects folder read-write, added folders read-only).
   **Anything the service spawns inherits host networking**; the container gives no network
   boundary for a child process.
2. The service has **no Docker socket** (DR-P3.1). Host authority lives in the narrow host helper
   (`scripts/control-helper`): signed, versioned request kinds, a fixed allowlist, serialized,
   durable results.
3. The no-live-model guard (`scripts/lib/check-guard`) already reserves
   `Lockstep.Effects.Provider.Live` as the only module that may construct a live provider, importable
   only from `app/lockstep/Main.hs` and `app/lockstep-smoke/*`; tests run with `claude`/`codex`
   sentinel shims and fail if one is ever invoked.
4. On this Mac the Claude CLI authenticates through the login keychain (needs `USER`; a container
   cannot reach it). A container needs a token in its environment (`CLAUDE_CODE_OAUTH_TOKEN` from
   `claude setup-token`, or `ANTHROPIC_API_KEY`). Codex is not installed.
5. Profiles (C-P2.3) already have the artifact kinds a Bug Profile needs (`reproduction`,
   `impact-assessment`, `requirements-basis`, `frozen-tests`, `verification-record`,
   `review-record`, `regression-evidence`) and the nine universal invariants
   (`single-implementer`, `protected-frozen-tests`, `independent-review`, `legitimate-commits`,
   `human-completion`, …).

---

## DG-17 — live coding confinement

### D-17.1 Where an agent process runs

| Option | What it is | Network boundary | Filesystem boundary | Fit with DR-P3.1 |
|---|---|---|---|---|
| **(a) Runner container per invocation, started by the host helper** | A new helper request kind `run-role` with fixed, versioned parameters; the helper runs `docker run` with a pinned runner image, no Docker socket, `--cap-drop ALL`, `--security-opt no-new-privileges`, read-only root, `--pids-limit`, `--memory`, `--cpus`, a non-root user, and only the mounts of D-17.2 | real: `--network none`, or for a live provider an internal network whose only exit is an allowlist proxy (D-17.4) | real: only what is mounted | yes: the helper already holds host authority; the service still has none |
| (b) Confinement inside the service container (Landlock + seccomp + rlimits) | The service spawns the agent itself and restricts it with Linux mechanisms | **none**: the service is `--network host`; Landlock can restrict TCP ports, not hosts | good (Landlock) | no helper change, but no network boundary |
| (c) The provider CLI's own permissions and sandbox only | `--allowedTools`, permission modes, the CLI's built-in sandbox | the provider's | the provider's | rejected by NFR-19 and the handoff: provider assurances are not a host boundary |

**Recommended: (a)**, with the provider's own permission flags kept as defence in depth
(D-17.6), never as the boundary. Scripted (model-free) roles run through exactly the same
container path, so the deterministic suite exercises the real boundary.

### D-17.2 What the Implementer can touch: a Git-free snapshot

| Option | Commit authority |
|---|---|
| **(a) A snapshot** — the tree of the exact basis commit exported into a Lockstep-owned staging folder, **without `.git`**; protected tests mounted read-only on top; the Supervisor diffs the snapshot against the basis afterwards and applies an accepted diff itself | **none by construction**: no repository exists in the container |
| (b) A linked worktree | the worktree's `.git` file points at the shared common directory: the agent could write objects, refs and commits (forgeable Supervisor history) |

**Recommended: (a).** After the run the host computes the change set and refuses unless
`changed ⊆ allowed paths`, `changed ∩ protected tests = ∅`, no symbolic link or special file is
introduced, and every protected-test digest still matches (PY-REG-03). The canonical repository is
touched only by the Supervisor (P4.4/P4.14), never by a container.

### D-17.3 Which repositories may execute at all

| Option | |
|---|---|
| **(a) Phase 4: only a project in Lockstep's own projects folder** (mounted read-write) | an added (existing, read-only) folder is "organized, not executable"; the person can place the repository under the projects folder |
| (b) Mount an added folder read-write once a person enables execution for its project | broader; changes the C-P3.5 J5 host contract (a helper and `scripts/service` change, its own Contract) |

**Recommended: (a) for Phase 4**, (b) later. P4.1 is being built to (a): enabling execution for a
read-only folder is refused in plain words.

### D-17.4 Network

**Recommended:** `--network none` for scripted roles, the snapshot export, verification commands
(P4.11) and every read-only role that needs no model. A live provider role gets an internal Docker
network whose only route out is a small allowlist proxy (HTTP `CONNECT` to the provider's API
hosts only, e.g. `api.anthropic.com:443`); every other destination is refused and logged as
evidence. Package downloads, Git remotes and arbitrary URLs are unreachable from every role.

### D-17.5 Credentials

**Recommended:**

- The only secret a container ever receives is **one provider token** for a **live** role, placed
  by the helper into that one container's environment for that one invocation. It is stored
  host-side by the helper (mode 0600, outside any repository), entered by the owner once (a
  dedicated `claude setup-token` token or API key, not the keychain login).
- Never mounted or passed: the owner's home, SSH keys, Git credentials or config, the keychain, the
  Docker socket, Lockstep's database credentials, the operator token, other providers' tokens.
- Stated limitation: a live agent can read its own provider token (the CLI needs it). The network
  allowlist (D-17.4) limits where it could be sent; the token should be dedicated and revocable.

### D-17.6 Provider CLI flags (defence in depth, not the boundary)

**Recommended:** non-interactive mode with structured output, a pinned CLI version inside the
runner image, an explicit tool allowlist per role (the Implementer: read/edit/write and a shell
inside the container; the Planner, challenger and Reviewer: read-only tools), a turn limit, no MCP
servers, settings from a Lockstep-supplied file only. The target repository's own `CLAUDE.md` or
`AGENTS.md` is **untrusted input** (prompt-injection material), never instructions with authority.

### D-17.7 Finite limits (all host-enforced; numbers are proposals)

| Limit | Proposal |
|---|---|
| Wall clock per invocation | Implementer 20 min; Planner, challenger, Reviewer 10 min each; verification command 10 min |
| Output captured | 8 MiB stdout, 2 MiB stderr per process; beyond that the process is killed and the result is `output-limit` (never PASSED) |
| Processes / memory / CPU | `--pids-limit 256`, 4 GiB, 2 CPUs |
| Attempts per Work Unit | Implementer at most **2** (the second only after a typed failure or a confirmed counterexample); Planner candidate corrections at most 2 (DG-06); challenger 1 per candidate; Reviewer 1 per candidate implementation |
| Live usage | an owner-set ceiling per trial (number of invocations); the first live smoke is separately consented (P4.17) |

A timeout, a killed process or a lost result is `UNKNOWN`/`INCONCLUSIVE`, never PASSED, and a
model invocation is a class-D effect (C-P2.5): **never re-run automatically** after an uncertain
outcome; a human decides.

### D-17.8 Provider families

**Recommended:** the adapter interface is family-neutral (role, Context Pack, typed result); the
first live family is **Claude Code CLI** only (installed, the owner's account). Codex is not
installed and is not needed for C-EXEC.

### D-17.9 Verification environment (PY-REG-01)

**Recommended:** verification commands are argv lists (no shell launcher) recorded in the Contract
and run in the same pinned runner image as the role invocations, `--network none`, against a fresh
snapshot of the exact candidate tree. The baseline (P4.8) and the candidate verification (P4.11) use
the same image and argv; a project whose toolchain is not in the image is refused as
`verification-environment-missing` (a later decision can add per-project images).

### Minimum DG-17 decision

Accept or amend D-17.1 to D-17.9. If only part is accepted, the smallest set that unblocks the
**model-free** engine (P4.2, P4.4, P4.5 scripted, P4.10 scripted) is **D-17.1(a), D-17.2(a),
D-17.3(a), D-17.4 (`none` part), D-17.7, D-17.9**; the live parts (D-17.4 proxy, D-17.5, D-17.6,
D-17.8) can be decided before the live smoke.

---

## DG-06 — test-candidate baseline, RED policy, source-grounded acceptance

### D-6.1 Classify each candidate test separately (PY-REG-02)

**Recommended:** every candidate test file is declared either **RED** (must fail at the basis,
because of the bug) or **GREEN-REGRESSION** (must pass at the basis and after). Each RED test also
declares a **failure signature** (a literal string its failing output must contain, e.g. the
assertion message), so "fails for the expected reason" is checked, not assumed (the C-P3.4
`HandoverTest.hs` lesson). Baseline classes, each distinct:

| Class | Meaning | Freeze? |
|---|---|---|
| `red-confirmed` | RED test failed with its signature | yes |
| `red-unexpectedly-passed` | RED test passed at the basis | no: inadequate or wrong test |
| `red-wrong-reason` | RED test failed without its signature (compile error, missing import, broken setup) | no: `setup-invalid` |
| `green-confirmed` | GREEN test passed | yes |
| `green-regression-failed` | GREEN test failed at the basis | no: the basis is already broken; hard stop for a human |
| `timed-out`, `launch-failed`, `output-limit` | the run itself failed | no; never treated as RED |

### D-6.2 Exact targets and scope (PY-REG-03)

**Recommended:** tests are individual regular files (no directories, no symbolic links, nothing
nested under a file); `allowed implementation paths ∩ test paths = ∅`; acceptance requires
`changed ⊆ allowed` and `changed ∩ protected = ∅`; the host never rewrites a Planner path.

### D-6.3 Source-grounded acceptance

**Recommended:** each acceptance criterion cites the Ticket text it serves and at least one source
location (path and line range) that exists at the basis commit; the host checks each citation and
records the SHA-256 of the cited lines. A bug Contract also cites its reproduction record (D-6.6).

### D-6.4 Corrections before the freeze (PY-REG-04)

**Recommended:** at most **2** Planner correction rounds (3 candidates) from typed findings
(baseline classes, D-7 confirmed findings). Each candidate starts from a pristine snapshot of the
same basis. Correction rounds do not spend Implementer attempts. Not correctable (stop for a
human): `green-regression-failed`, an environment failure, a scope violation. On exhaustion: no
freeze, no Implementer, a truthful stage.

### D-6.5 After the freeze

**Recommended:** frozen tests never change inside the Work Unit. A genuine defect needs a human
amendment decision with exact diff and digests (the Phase 1–3 protocol), through P4.15.

### D-6.6 Missing reproduction (P4.6; Bible §31.1 "reproduction or justified non-reproducibility")

**Recommended:** missing reproduction **blocks** the freeze. The only other path is a human decision
on a durable request that records the evidence for non-reproducibility (the Bug Profile's
reproduction gate allows a human exception and nothing else); an agent cannot self-certify it.

### Minimum DG-06 decision

Accept or amend D-6.1 to D-6.6 (all six are needed by P4.8).

---

## DG-07 — semantic challenger independence, budget, dispositions

### D-7.1 Independence

**Recommended:** the challenger is a separate invocation in its own runner container with a
**read-only** mount of the snapshot and candidate tests, given only the Ticket, the Contract, the
tests, the reproduction record and the source, **never** the Planner's or Implementer's transcript.
Same model family is permitted (only Claude is available) and recorded as "independent in process
and context, not in model family". Implementer-side advice (FR-AUX-01) never counts as independent.

### D-7.2 Typed findings and host confirmation

**Recommended:** each finding has: requirement reference, claim, basis, an optional
**counterexample**, and a disposition: `CONFIRMED`, `DISPROVED`, `NEEDS_HUMAN`, `INCONCLUSIVE`.
A counterexample is a **mutant patch**: a change to the source that should be rejected by the
requirement. The host applies it to a scratch snapshot and runs the candidate tests:

- pre-freeze: the mutant **passes** the candidate tests → `CONFIRMED` (the tests are inadequate);
  the mutant fails them → `DISPROVED`;
- post-implementation: the challenger may also submit an extra test that the host runs against the
  candidate implementation; it fails with its declared signature → `CONFIRMED` (wrong-but-green).

A finding without a runnable counterexample can be `NEEDS_HUMAN` or `INCONCLUSIVE`, never
`CONFIRMED`: a green claim is not an observation, and neither is a red one.

### D-7.3 Consequences

**Recommended:**

| Disposition | Pre-freeze | Post-implementation |
|---|---|---|
| `CONFIRMED` | back to the Planner for a correction round (D-6.4); the freeze is refused while it stands | blocks acceptance; the counterexample goes to the Implementer's second attempt if one is left, else a human |
| `NEEDS_HUMAN` | a durable human request (P4.15); blocks the freeze | a durable human request; blocks acceptance |
| `INCONCLUSIVE` | recorded and shown; does not block by itself | recorded and shown to the human at Done as an unresolved finding |
| `DISPROVED` | recorded | recorded |

### D-7.4 Budget

**Recommended:** one challenge per test candidate (at most 3 pre-freeze) and one per candidate
implementation (at most 2), each under the D-17.7 limits.

### Minimum DG-07 decision

Accept or amend D-7.1 to D-7.4.

---

## Also for the owner (not design gates, recorded so they are not decided silently)

| # | Item | What the Implementer is doing meanwhile |
|---|---|---|
| O-1 | **Bug Profile content.** Bible §31.1 says exact templates "belong in the release PRD"; PRD v0.3 gives none. P4.1 builds a built-in `lockstep-bug-fix` version 1 profile that **only adds** checks for work classed `bug`, mapped one to one from §31.1 (reproduction with a human-only exception path; impact and requirements basis; failing regression tests frozen; verification; regression evidence; independent review), all checked before acceptance. Adding checks can only make work stricter (C-P2.3). | Built in P4.1; review and amend if you want different gates (a new version, never an edit). |
| O-2 | **UX-C8 and UX-C9** remain NOT_RUN — DEFERRED BY OWNER. | Reported in the C-EXEC packet; not run by automation. |

## Human decision

*(empty — for the owner)*
