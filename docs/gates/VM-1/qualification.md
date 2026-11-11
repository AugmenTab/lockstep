# Gate VM-1: qualification record (P5.1–P5.11 qualified; P5.12 blocked)

Everything below is **model-free**. No provider was contacted, and only synthetic credentials were used (an
`sk-ant-oat01-fake-…` OAuth file in a throwaway Docker volume). Model invocation count: **0**. The live paths ran
the real pinned Claude Code CLI 2.1.312 against the scripted stand-in upstream on an internal network. **This is
not evidence of a real subscription session.** The Implementer does not accept this gate; the owner does.

## Subphase status (after update 1, `.local/plans/phase-05_update1.md`)

| Subphase | Status | Evidence |
|---|---|---|
| P5.1 architecture, contracts, tool routing | **Done**, reviewed (`docs/reviews/phase-05-p5.1-review.md`) | `docs/architecture/dev-capsules.md`; `check-capsule-bridge` 34/34 (`evidence/p5.1-bridge-r3/`) |
| P5.2 Capsule Runtime and VM provisioning | **Qualified** on a real VM | `check-capsule-vm` 77/77 (`evidence/update1-vm/`) |
| P5.3 workspace and snapshots | **Qualified** on a real VM | W1–W5 |
| P5.4 guest Docker and development freedom | **Qualified, D4 included** (`hostLoopback: false`, enforced) | D1–D7, D4.1–D4.8 with a negative control; remaining LAN exposure: `escalation-host-network.md` §2 |
| P5.5 provider-to-capsule bridge, live | **Qualified** (stand-in), reviewed (`docs/reviews/phase-05-p5.5-review.md`) | `check-capsule-runner` C0–C3, E1 |
| P5.6 integration with the run channel | **Qualified** | A0–A4, E3–E6 |
| P5.7 independent verification | **Qualified**: a separate VM restored from a trusted snapshot before every run; exact tree | B0–B5, E2 |
| P5.8 Supervisor Git | **Qualified** | `lockstep-capsule` C-P5.8 (38/38, `evidence/lockstep-capsule-update1.log`) |
| P5.9 recovery | **Qualified** for: helper stop, helper crash, the run's own process dying, VM killed mid-run, executor crash, stale template | `check-capsule-recovery` 19/19 (`evidence/update1-recovery/`); runner A4; VM R2 |
| P5.10 preflight and operator view | **Qualified** | preflight (VM D4.8, recovery R3); `lockstep-capsule` C-P5.10; runner U5 |
| P5.11 full synthetic transaction through the real service | **Qualified** (scripted roles) | `check-capsule-e2e` 6/6 (`evidence/update1-e2e/`) |
| P5.10 LAN exception (update 2) | **Qualified**: scoped, expiring, exact; the LAN prerequisite for the attended Brigid run is satisfied under `lan-exception.md` | `check-capsule-lan` 42/42 (`evidence/update2-lan/check/`) |
| P5.12 Brigid / Gate VM-1 | **Ready for the attended live run**: Brigid's capsules prepared, its real test suite passing in verification from the snapshot, preflight 0 failures. **Waits on the owner's live-run authorization** | `brigid-readiness.md`; `evidence/update2-brigid/` |

Regression on the final tree: `scripts/check --integration`: format, lint, build, unit 870/870, guard, integration
571/571, backup/restore (`evidence/check-integration-update1.log`).

## D4: closed and enforced (update 1 §2–§3)

The template sets `networkOpts.hostLoopback: false`, and the effective configuration has it
(`evidence/update1-vm/lima.yaml.good`). Results:

- **Probes.** A probe bound to the host's 127.0.0.1 answers on the host. The guest cannot reach it through
  `192.168.5.2` or `host.lima.internal`, and cannot reach an all-interfaces probe through the gateway either. The
  same holds for 2375, 5432, 8000, 22, 5000, 7000, 5984 and 4444.
- **Guest still works.** Guest DNS, HTTPS, `apt-get` and `docker pull` work.
- **Negative control.** With the setting removed and the VM started by `limactl` directly (test only), the guest
  **does** reach the loopback probe. The setting is what closes it.
- **Refusals.**
  - Drift, `true` in both config and record, a removed setting, and a Lima older than 2.3.0 are all refused.
  - Inspect and preflight name the cause.
  - `reconfigure` brings an older capsule over and keeps its disk and snapshot. It never reprovisions; a base-image
    change is refused.

**Remaining exposure:** the guest can reach the Mac's LAN address, as any LAN device can, including 14 ports this
run found open there. None is Lockstep's. Preflight refuses while they are open. The owner decision requested is
`escalation-host-network.md` §3 (E1/E2/E3). Isolation is **not** complete until then.

## The milestone (handoff §21), met on a real VM

`scripts/lib/check-capsule-vm` shows that the Capsule Runtime:
1. Provisioned a Lima/VZ Ubuntu 24.04 arm64 VM, its configuration audited.
2. Installed Docker Engine and Compose inside it.
3. Imported a project.
4. Ran its `scripts/test`: C build and test, a Docker image, and a Compose service with a dependency.
5. Kept the workspace, artifacts, Docker cache, images and packages across stop and start.
6. Snapshotted and restored the whole disk.
7. Served bridged calls with timeout, cancellation and crash recovery.
8. Survived a full disk.
9. Shut down cleanly.

All with no LLM and no unrestricted host shell.

### Configuration and measured timings (`evidence/update1-vm/timings.txt`)

- Lima `2.3.0`, `vmType: vz`. Ubuntu 24.04 cloud image (URL, **not digest-pinned**). Profile `small`: 2 vCPU,
  4 GiB, 30 GiB, a 1800 s command limit. Host: Apple Silicon, 10 cores, 64 GiB.

| Step | Seconds |
|---|---|
| Cold provision (image cached by Lima) | 46 |
| Repeat provision | 0 |
| Cold project build and test (C, Docker image, Compose) | 18 |
| Stop / warm start | 2 / 7 |
| Warm project build and test | 1 |
| Snapshot / restore (APFS clone; includes stop and start) | 13 / 12 |
| Reconfigure (already current) | 0 |
| P5.11 transaction, hand-over to Done (10 capsule runs) | 262 in total: about 75 in the capsule runs; the rest is service start, the browser and the person's steps (1525 before the polling fix) |

## The capsule mode with the real helper (`check-capsule-runner`, 91/91)

The real `control-helper --runner` received signed runner requests exactly as the service sends them.

- **Scripted runs:**
  - A writing run's tree comes back as regular files. Protected files stay the Supervisor's, and a change to one is
    reported.
  - Ignored build output stays in the guest. A read-only run's writes never come back.
- **Verification** runs in a separate VM restored from its trusted `verify` snapshot before every run, with exactly
  the Supervisor's tree:
  - An Implementer that fakes `make` in its own VM gets a fake pass there, but verification of the same buggy tree
    stays **RED**.
  - A verification run that plants a fake tool and a lingering process does not affect the next one.
  - The fixed tree is **GREEN** for the real reason.
- **Live roles** (real CLI, stand-in):
  - The argv that starts a role is refused if it keeps any built-in tool or brings its own MCP config.
  - Answers are written on the host, never in a guest.
  - There is no credential or provider variable in a capsule.
  - Read-only roles run in the restored verification capsule.
  - A forger process in the Implementer's VM cannot change a reviewer's answer.
- **Robustness:**
  - A cancel gives `cancelled`, with the tree discarded.
  - A symlink in the tree means it is refused.
  - The guest's `.git` never comes back.
  - A broken config refuses every run, with no fallback to containers.
  - A run whose own process dies is answered `interrupted` in under a second (A4), not after the command limit.

## P5.11 (`check-capsule-e2e`)

The Gate C-EXEC journey, in a real browser against the real service and PostgreSQL, with the engine's runner being
the helper's channel in capsule mode:
- The person makes a project, allows execution, writes the bug and hands it over.
- The transaction stops on an uncommitted change; the person retries.
- Planning, challenge, implementation and review all run in capsules, and the change is committed.
- The person marks the bug done.

Results:
- 6 runs in the Engineer's capsule, 4 verifications in the verification capsule, none in the Engineer's capsule,
  none in a container.
- `main` did not move. Lockstep's commit is on the work branch, with the fixed `calc.py` and the frozen test.
- There is no remote.

## Before Brigid (P5.12): exact blockers (update 2)

1. ~~The owner's decision on the LAN-address exposure.~~ Decided on 2026-11-11 (`lan-exception.md`).
2. **Separate authorization of a real-provider session** (phase-05 §5; not given).
3. The operator steps in `brigid-readiness.md` §5. They touch the installed service and the helper state,
   outside this repository.
4. Brigid will be the **first live use** of the capsule path with a real model. Until then the live path is
   qualified only against the stand-in.

## Known limitations

1. The guest can reach the Mac's LAN address. Preflight refuses any listener there unless the owner's scoped
   exception names it (`lan-exception.md`). There is no packet filter; a host-enforced boundary is deferred
   work, required before unattended or multi-project use. Public egress is open and not recorded per destination.
   `hostResolver` gives the guest the host's DNS.
2. The VM image is not pinned by digest.
3. A full guest disk grows the host's sparse file to the profile's size; VZ does not reclaim it (28 G after the
   disk-full test).
4. Read-only roles have no command tool.
5. On pull, a tracked file that `.gitignore` matches is missing from the returned tree. This fails closed.
6. Processes an Implementer leaves keep running in its own capsule. They cannot affect verification, review or
   answers.
7. Not qualified:
   - a host reboot mid-run;
   - two capsules running at once;
   - hard-link and mode-000 tar fixtures;
   - P5.11 with live roles;
   - P5.11 driving the capsule section in the browser (review L4).
8. `reconfigure` is not serialised against an active run (review L6). Run it while Lockstep is idle.
