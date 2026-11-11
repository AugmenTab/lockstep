# Host network isolation: D4 resolved; the remaining LAN-address exposure (decision requested)

- **For:** the owner. **Updated:** 2026-11-10 under `.local/plans/phase-05_update1.md` (Option D).
- **Correction to the first version of this document:** it said "no Lima setting turns that translation off". That
  was wrong. Lima 2.3.0 has `networkOpts.hostLoopback: false` for exactly this purpose. I had not checked the
  network documentation.

## 1. D4: resolved (measured, `evidence/p5.2-p5.4-vm/`, run `capsule-vm-20261110t183150z`)

`scripts/capsule/lima-capsule.yaml` now sets `networkOpts: { hostLoopback: false }`. The Capsule Runtime enforces it:

- The audit requires **exactly one** `hostLoopback` line in the effective configuration, with the value **false**,
  inside `networkOpts`. Anything else is refused: absent, `true`, or repeated (`audit-host-loopback-not-disabled`).
  Drift against the recorded copy is refused as before (`audit-config-changed`).
- The Lima version must be at least 2.3.0, and provisioning is refused if Lima reports `networkOpts` or
  `hostLoopback` as an unknown field. An older Lima would otherwise ignore the setting and leave the gateway open.
- `reconfigure` brings a capsule made before the change to the new configuration without touching its disk,
  snapshots or caches. It never reprovisions.
- Preflight reports `host-loopback-isolation`, and `capsule-healthy` fails on any audit failure.

| # | Required (update 1 §3) | Result |
|---|---|---|
| 1 | The host-loopback service is reachable from the host itself | PASS (HTTP 404 from the probe) |
| 2 | The guest cannot reach it through 192.168.5.2 | PASS |
| 3 | …nor through `host.lima.internal` | PASS |
| 4 | An all-interfaces host service is not reachable through the Lima gateway | PASS (18766 via both names). The same holds for 2375, 5432, 8000, 22, 5000, 7000, 5984 and 4444 via 192.168.5.2 |
| 5 | Guest DNS and public downloads work | PASS (DNS, HTTPS to `registry-1.docker.io`, `apt-get install`, `docker pull`) |
| 6 | `limactl shell`, the bridge and guest Docker work | PASS (D1, D5, D6, B1–B3, R2; `check-capsule-runner` 81/81) |
| 7 | The effective configuration contains the setting | PASS (`effective-lima.yaml`) |
| 8 | Removing or reversing it makes preflight refuse | PASS (reversed: refused; removed: refused, `inspect` names it, preflight `FAIL capsule-healthy … host-loopback-not-disabled`; after `reconfigure`, data and snapshot kept, preflight passes) |

## 2. Remaining exposure: services bound beyond loopback (update 1 §4)

`hostLoopback: false` closes only the gateway's mapping to the host's loopback. The guest's ordinary outbound traffic
can still reach **the Mac's LAN address** (10.10.1.203 at the time of the run), as any device on the LAN can. Every
host service bound to all interfaces is therefore reachable from the guest. Measured from inside the capsule:

| Port | Service (`docker ps`, `lsof`) | Reachable | Exposes |
|---|---|---|---|
| 8320 | MariaDB of `development-easy` (OpenEMR dev stack) | yes | **a database** (protected data if real records are loaded) |
| 8310 | phpMyAdmin of the same stack | yes | **database administration** |
| 8300, 9300 | OpenEMR (HTTP, HTTPS) | yes | an EHR application |
| 5984, 6984 | CouchDB of the same stack | yes | **a database admin API** |
| 4444, 7900 | Selenium standalone Chromium (WebDriver, VNC) | yes | **remote control of a browser** (that runs in its own container) |
| 8780, 8781 | polygon-pong web and server | yes | a development app |
| 5000, 7000 | macOS Control Center (AirPlay receiver) | yes | an Apple service |
| 50966 | macOS `rapportd` | yes | an Apple service |
| 18765 | the probe bound to 127.0.0.1 | **no** | (closed by `hostLoopback: false`) |
| 8000, 5432, 22 | Lockstep's service, PostgreSQL, SSH (not listening beyond loopback) | **no** | |

**None of Lockstep's own services is reachable.** These are the owner's other projects' development containers and
two macOS services, published on all interfaces. They are reachable from the owner's whole LAN today, with or
without capsules. A capsule adds one more untrusted client with that same access.

**What is enforced now (outside the guest):** `scripts/capsule-preflight` fails `host-network-exposure` and names
each exposed port. It reads `netstat`, which lists every socket on the host whoever owns it (TCP listeners and
bound UDP sockets beyond loopback), unless the owner explicitly accepts the port with `--allow-lan` or
`--allow-lan-udp`. The first version used `lsof`, which sees only the caller's own processes (review 3, H1).
This is a host-side refusal to start, not a packet filter: a service that starts listening after the preflight is
not blocked. On a typical Mac, UDP system services (for example mDNS on 5353) will need explicit acceptance.

## 3. Decision requested (the smallest one)

| # | Option | Effect | Cost |
|---|---|---|---|
| E1 | **Bind the owner's development services to 127.0.0.1** (in those projects' Compose files, e.g. `127.0.0.1:8320:3306`), and turn off the AirPlay receiver while capsules run. Preflight keeps enforcing. | Those services become unreachable from capsules (and from the LAN) through the now-closed loopback path | Edits in other projects (not Lockstep's to make); no root |
| E2 | **A `pf` anchor** (one-time admin setup by the owner) blocking traffic from the capsule VMs' NAT to the Mac's own addresses | A packet-level boundary outside the guest that also covers services started later | Needs sudo; I can write and qualify the anchor once authorized |
| E3 | Accept the listed ports for development use (`--allow-lan`) | Brigid can proceed; residual risk recorded | None |

The Implementer recommends **E1 for Brigid**: nothing Brigid needs depends on those services, and the preflight already
refuses while they are exposed. **E2** is the durable control if capsules are to run while such services stay up.
