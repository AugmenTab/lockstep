# Gate VM-1: qualification record (in progress)

Everything below is **model-free**. No provider was contacted, and only synthetic credentials were used (an
`sk-ant-oat01-fake-…` OAuth file in a throwaway Docker volume). Model invocation count: **0**. The live paths ran
the real pinned Claude Code CLI 2.1.312 against the scripted stand-in upstream on an internal network. **This is
not evidence of a real subscription session.**

## Subphase status

| Subphase | Status | Evidence |
|---|---|---|
| P5.1 architecture, contracts, tool routing | **Done**, reviewed (`docs/reviews/phase-05-p5.1-review.md`) | `docs/architecture/dev-capsules.md`; `check-capsule-bridge` 34/34 (`evidence/p5.1-bridge-r3/`) |
| P5.2 Capsule Runtime and VM provisioning | **Qualified** on a real VM | `check-capsule-vm`: L1–L6 PASS (`evidence/p5.2-p5.4-vm/`) |
| P5.3 workspace and snapshots | **Qualified** on a real VM | W1–W5 PASS |
| P5.4 guest Docker and development freedom | **Qualified except D4** (guest reaches host loopback) | D1–D3, D5–D7 PASS; D4 → `escalation-host-network.md` |
| P5.5 provider-to-capsule bridge, live | **Qualified** (stand-in) and reviewed (`docs/reviews/phase-05-p5.5-review.md`) | `check-capsule-runner` C0–C3, E1 |
| P5.6 integration with the run channel | **Qualified** for the helper's runs (scripted, read-only, live); the service selects the capsule adapter | A0–A3, E3–E6; `lockstep-capsule` 24/24 |
| P5.7 independent verification | **Qualified**: a separate VM restored from a trusted snapshot before every run; exact tree | B0–B5, E2 |
| P5.8 Supervisor Git | **Partly by construction, not yet qualified on its own.** The guest's `.git` never returns (E5), only regular files return (E4), and the Supervisor's Git keeps its Phase 4 safety options | E4, E5 |
| P5.9 recovery | Partly: an executor crash → `effect-unknown`, never replayed (R2); cancel and deadline (E3); stale bindings closed; a VM gone mid-run → `launch-failed`. **Not yet:** host reboot, base-image change, helper restart mid-run in capsule mode | R2, E3 |
| P5.10 preflight | **Qualified** (automated, names each failing prerequisite). UI integration not started | D1–D3 |
| P5.11 full synthetic transaction through the real service | **Not started**: it needs the web pane driven by a browser driver and a role-aware stand-in producing valid role documents | — |
| P5.12 Brigid / Gate VM-1 | **Blocked**: needs P5.11, the D4 decision, and a separately authorized live session | — |

Regression: `scripts/check --integration` with the helper changes: unit 870/870, integration 571/571, format, lint,
guard, backup/restore (`evidence/check-integration-8392c68.log`; re-run after the second review's fixes, see below).

## The milestone (handoff §21), met on a real VM

`scripts/lib/check-capsule-vm` shows that **Lockstep's Capsule Runtime**:

1. Provisioned a Lima/VZ Ubuntu 24.04 arm64 VM, its configuration audited.
2. Installed Docker Engine and Compose inside it.
3. Imported a project.
4. Ran its project-defined `scripts/test`: a C build and test, a Docker image, and a Compose service with a dependency.
5. Kept the workspace, artifacts, Docker cache, pulled images and installed packages across a stop and start.
6. Snapshotted and restored the whole disk.
7. Served bridged calls with timeout, cancellation and crash recovery.
8. Survived a full disk.
9. Shut down cleanly.

All of it with no LLM and no unrestricted host shell. The only failures are the two D4 lines.

### Configuration and measured timings

- Lima `2.3.0`, `vmType: vz`. Ubuntu 24.04 cloud image (URL, **not digest-pinned**). Profile `small`: 2 vCPU,
  4 GiB, 30 GiB, a 1800 s command limit. The effective configuration is `evidence/p5.2-p5.4-vm/effective-lima.yaml`.
- Host: Apple Silicon, 10 cores, 64 GiB.

| Step | Seconds |
|---|---|
| Cold provision (image cached by Lima) | 51 (79 on an earlier run) |
| Repeat provision | 0 |
| Cold project build and test (C, Docker image, Compose) | 19 (25 earlier) |
| Stop / warm start | 2 / 8 (2 / 16 earlier) |
| Warm project build and test | 2 |
| Snapshot / restore (APFS clone; includes stop and start) | 14 / 13 |

Final run: 53 PASS, 2 FAIL (both D4), `evidence/p5.2-p5.4-vm/results.txt`.

Disk: 3.3 G used in the guest after the qualification. On the host the VM directory is 28 G after the disk-full test,
because VZ does not return trimmed blocks.

## The capsule mode, end to end with the real helper (`check-capsule-runner`, 80/80)

The real `control-helper --runner` received signed runner requests exactly as the service sends them.

- **Scripted runs** in the Engineer's capsule. A writing run's tree comes back as regular files. Protected files stay
  the Supervisor's, and a guest change to one is reported. Ignored build output stays in the guest. Read-only writes
  never come back.
- **Verification** runs in a separate VM restored from its trusted `verify` snapshot before every run, with exactly
  the Supervisor's tree. An Implementer that installs a fake `make` in its own VM gets a fake "pass" there, but
  verification of the same buggy tree stays **RED**. A verification run that plants a fake tool and a lingering
  process does not affect the next one. The fixed tree is **GREEN** for the real reason.
- **Live roles** (the real CLI, the stand-in). An argv that keeps any built-in tool, or brings its own MCP config, is
  refused before anything starts.
  - The Implementer reads its instructions (served from the host), edits, builds and tests in its capsule, and answers.
    The answer is written by the bridge on the host side, never in a guest.
  - There is no built-in Bash, and no credential or provider variable in the capsule. Usage is 840 tokens (synthetic).
  - A read-only role runs in the restored verification capsule, has no write or exec tool, and answers.
  - A forger process left in the Implementer's VM cannot change the reviewer's answer.
- **Robustness:**
  - A cancelled capsule run is reported `cancelled`, its tree is discarded, and the capsule is usable after.
  - A symlink in the guest's tree means the tree is refused and the Supervisor's is unchanged.
  - The guest's `.git` (hooks, config) never comes back, and the Supervisor's `.git` is kept.
  - A broken capsule config refuses every run; nothing falls back to the Phase 4 containers.
- **Preflight** passes every prerequisite on a healthy setup, names host loopback exposure, and names a failing
  toolchain probe exactly.

## Known limitations

1. **D4** (escalated): guest code can reach services on the host's loopback.
2. The VM image is not pinned by digest.
3. A full guest disk grows the host's sparse file to the profile's size; VZ does not reclaim the space.
4. Public egress is open and not recorded per destination. `hostResolver` gives the guest the host's DNS.
5. Read-only roles have no command tool. They can read and search the Supervisor's tree in the verification capsule.
6. On pull, a tracked file that the project's `.gitignore` matches is missing from the returned tree. This fails
   closed: the change looks out of scope, never wrongly accepted.
7. Guest processes left by an Implementer keep running in its own capsule. They can no longer affect verification,
   review or answers, but they can affect its own later attempts.
8. Not yet qualified: hard-link and mode-000 tar fixtures, a helper restart in the middle of a capsule run, a host
   reboot, a base-image change, two capsules at once.
9. P5.11 and P5.12 not done (above).
