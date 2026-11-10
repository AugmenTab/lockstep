# Gate VM-1: qualification record (in progress)

All runs below are **model-free**. No provider was contacted, and no real credential was used. Model invocation
count: **0**.

## Subphase status

| Subphase | Status | Evidence |
|---|---|---|
| P5.1 architecture, contracts, tool-routing spike | **Done**, reviewed (`docs/reviews/phase-05-p5.1-review.md`) | `docs/architecture/dev-capsules.md`; `evidence/p5.1-bridge/`, `evidence/p5.1-bridge-r2/` (34/34) |
| P5.2 Capsule Runtime and VM provisioning | **Qualified** on a real VM | `evidence/p5.2-p5.4-vm/` (L1–L6 all PASS) |
| P5.3 workspace and snapshots | **Qualified** on a real VM | W1–W5 all PASS |
| P5.4 guest Docker and development freedom | **Qualified except D4**: guest-to-host-loopback reachability | D1–D3, D5–D7 PASS; **D4 FAIL** → `escalation-host-network.md` |
| P5.5 provider-to-capsule bridge | Bridge proven on the fixture (T1–T15). Helper capsule mode for live runs **written, not yet qualified** | `scripts/capsule/helper-capsule.sh` |
| P5.6 integration with the transaction engine | Helper capsule mode for scripted and proof runs **written, not yet qualified**; the service's capsule adapter is built | — |
| P5.7 independent verification | Design (§8): a separate verification capsule restored from its trusted `verify` snapshot. Helper path **written, not yet qualified** | — |
| P5.8–P5.11 | Not started | — |
| P5.12 Brigid / Gate VM-1 | Blocked: needs P5.5–P5.11, the D4 decision, and a separately authorized live session | — |

## The milestone (handoff §21), met on a real VM

`scripts/lib/check-capsule-vm` (run `capsule-vm-20261110t161115z`) shows that **Lockstep's Capsule Runtime**:

1. Provisioned a Lima/VZ Ubuntu 24.04 arm64 VM, its configuration audited (`audit=ok`).
2. Installed Docker Engine and Compose inside it.
3. Imported a project at its revision.
4. Ran the project-defined `scripts/test`: a C build and test, a Docker image build, and a Compose service with a dependency.
5. Kept the workspace, build artifacts, Docker cache, pulled images and installed packages across a stop and start.
6. Snapshotted and restored the whole disk.
7. Shut down cleanly.

There was no LLM involved and no unrestricted host shell. **53 PASS, 2 FAIL (D4).**

### Configuration and resources, as run

- Host: macOS on Apple Silicon (`host-os.txt`, `host-resources.txt`). Lima `2.3.0`, `vmType: vz`. Image: Ubuntu 24.04
  cloud image (arm64, `current` release URL; **not digest-pinned**, see limitations).
- Profile `small`: 2 vCPU, 4 GiB, 30 GiB disk, a 1800 s command limit. The guest reports `cpus=2 mem-kib=3998424`
  and a 29 G root.
- Effective Lima configuration: `evidence/p5.2-p5.4-vm/effective-lima.yaml` (`mounts: []`, no agent forwarding,
  all port forwarding ignored).

### Measured timings (one run; `timings.txt`)

| Step | Seconds |
|---|---|
| Cold provision (create, first boot, Docker install, guest setup) | 79 |
| Repeat provision (idempotent) | 0 |
| Import | 0 |
| Cold project build and test (C, Docker image, Compose) | 25 |
| Stop / warm start | 2 / 16 |
| Warm project build and test | 3 |
| Snapshot / restore (APFS clone, stop and start included) | 16 / 20 |

The image download is cached by Lima outside the repository, so the cold figure is with the image already cached.

## Limitations found so far

1. **D4**: the guest reaches services on the host's loopback (escalated).
2. The VM image is referenced by URL, not pinned by digest.
3. Filling the guest disk grows the host-side sparse disk to the profile's size. VZ does not return trimmed blocks
   (`fstrim` in the guest trimmed 13.6 MiB; the host directory stayed at 28 G).
4. Public egress from the guest is open and not recorded per destination. `hostResolver` gives the guest the host's
   DNS.
5. Read-only roles have no command tool (review finding 1).
6. Guest processes of a closed Implementer binding are not yet ended (review finding 9, P5.9).
