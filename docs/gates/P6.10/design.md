# P6.10a — Host-enforced capsule network boundary: threat model, design and qualification plan

- Status: **DESIGN, nonprivileged.** Written by the single writing agent (Implementer), 2026-11-14, on `phase-6`.
  Authority: `.local/plans/phase-06.md` §15 (P6.10a: "Do not modify host packet-filter rules in this increment").
  No host rule, `sudo`, installation or host probing was performed to write it. Measurements cited are Phase 5's
  recorded ones (`docs/gates/VM-1/escalation-host-network.md`, `lan-exception.md`).
- Decision it leads to: **D6-SEC** (§7, a narrow request).

## 1. Threat model

| # | Adversary | Goal | Today (Phase 5) | Required (P6.10) |
|---|---|---|---|---|
| N1 | Guest code or guest root (repository, dependency, container, prompt-injected tool use) | Reach a service on the Mac's LAN address (any service bound to `*`) | **Reachable** (measured: MariaDB, CouchDB, OpenEMR, WebDriver, AirPlay, …); only a preflight listing at start | Refused by a host rule the guest cannot change |
| N2 | Same | Reach host loopback services (Lockstep, PostgreSQL, control pane) | Closed: `networkOpts.hostLoopback: false`, audited | Stays closed; also covered by N1's rule |
| N3 | Same | Reach a host service that starts listening **after** the run started | **Reachable** (preflight is a snapshot) | Refused (the rule is by destination, not by listener inventory) |
| N4 | Same | Reach other LAN devices (router admin, NAS, printers, other machines) | Reachable | Refused, except the DNS resolver(s) the host actually uses, on port 53 only |
| N5 | Same | Reach another capsule | Not measured in Phase 5 (each VM has its own user-mode network) | Refused and measured (two capsules) |
| N6 | Guest root | Disable or bypass the boundary | n/a | Impossible: the rule lives in the host kernel (pf), keyed on host facts the guest does not control |
| N7 | Guest code | Host Docker socket, provider credentials, Supervisor Git/signing | Closed by construction (no mounts/sockets/forwards; credentials in another machine's container) | Unchanged; re-qualified |
| N8 | Host misconfiguration | The rule is absent after a reboot or was flushed | n/a | Unattended execution refuses to start (fail closed), and a running unattended execution halts at the next safe boundary |

Kept working: guest DNS; public HTTPS/HTTP package downloads (apt, ghcup, Stack, npm, cargo, Docker Hub); guest
Docker image pulls; the host → guest control channel (`limactl shell` over Lima's SSH, which the host initiates).

## 2. How guest traffic leaves the Mac (why the mechanism must be chosen by measurement)

The capsule uses Lima `vmType: vz` with Lima's **user-mode network** (gateway `192.168.5.2`, the
`host.lima.internal` name, `hostLoopback` option). In user-mode networking the guest's packets do not appear on a
host interface as a VM's packets: the per-VM `limactl` **hostagent process** terminates them and opens ordinary host
sockets on the guest's behalf. A connection from the guest to the Mac's LAN address (e.g. `192.168.1.197:8320`)
therefore reaches the host as a **local connection from the hostagent process, running as the owner's macOS user**,
to one of the host's own addresses.

Consequences (to be confirmed by M1–M3):

- A `pf` rule on a bridge interface (`bridge100`) would see nothing; the traffic is local.
- A rule that blocks "the owner's user" from reaching the host's own addresses would also block the owner's own
  tools. The rule must key on something only the capsules have.

## 3. Candidate mechanisms

| | Mechanism | Guest-root resistant | Cost / risk | Fit |
|---|---|---|---|---|
| **H1 (recommended, pending M1–M4)** | Run the Capsule Runtime's `limactl` (and so every hostagent) as a **dedicated unprivileged macOS user** (`_lockstep_capsule`), and install a **pf anchor** `com.lockstep.capsule` with rules matched by `user _lockstep_capsule`: block TCP/UDP to `self` (every host address, IPv4 and IPv6, loopback included) and to RFC 1918, link-local, CGNAT, ULA and multicast ranges; pass TCP/UDP 53 to the resolvers in `/etc/resolv.conf`/`scutil --dns` at install time; pass everything else (public internet) | Yes: rules are in the host kernel; the hostagent's uid is a host fact | One-time admin: create a user, install the anchor and a launchd job that loads it at boot. Requires the runtime to `sudo -u` (or a launchd agent) to run as that user — a change to how capsules are started; existing capsules' disks must be made readable by that user (or migrated). | Covers N1–N4, N3 by construction; N5 by "block self + private ranges" |
| H2 | Lima `vzNAT` network (macOS vmnet; a real `bridge100` interface) plus a pf anchor on `bridge100` blocking the capsule subnet → host/private ranges | Yes | vmnet's own NAT uses pf internally (Internet Sharing anchors); rule order and persistence across vmnet restarts are known to be fragile; needs `socket_vmnet` or root for vmnet on some versions — a host software installation | Plausible, more moving parts |
| H3 | Guest-side firewall (iptables/nftables in the VM) | **No** (guest root owns it) | — | Rejected (B23-09) |
| H4 | Keep the attended listener exception | **No** (snapshot only, N3) | — | Rejected for unattended use (handoff §15) |
| H5 | macOS Application Firewall (socketfilterfw) | No: it filters *incoming* connections to apps, not outbound from the hostagent | — | Rejected |

## 4. Rules (H1) — what would be installed (draft, not installed)

```pf
# /etc/pf.anchors/com.lockstep.capsule  (owner-installed; Lockstep never edits it)
table <lockstep_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, \
                                 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255, \
                                 ::1, fc00::/7, fe80::/10, ff00::/8 }
table <lockstep_dns> persist { RESOLVERS }        # filled from the host's resolver list at install time
pass  out quick proto { udp tcp } from any to <lockstep_dns> port 53 user _lockstep_capsule
block return out quick proto { tcp udp icmp icmp6 } from any to self user _lockstep_capsule
block return out quick from any to <lockstep_private> user _lockstep_capsule
```

`self` covers every address of every host interface (the LAN address included, whatever network the Mac joins) and is
re-evaluated as interfaces change. `block return` makes a refused connection fail at once (no timeouts; fail fast).
Loaded with `anchor "com.lockstep.capsule"` in `/etc/pf.conf` and `pfctl -E` from a launchd daemon at boot.

## 5. Measurements before choosing (nonprivileged unless marked)

| # | Measurement | How (proposed) | Decides |
|---|---|---|---|
| M1 | Which host process and uid owns the host socket of a guest → host-LAN connection | From the guest, `nc` to a host listener on the LAN address; on the host, `lsof -nP -iTCP@<lan>:<port>` while connected | Whether H1's `user` match sees the hostagent |
| M2 | Same for guest → public internet (TCP and UDP) and guest DNS | as M1, to a public host; `dig` in the guest | That H1 allows public egress and DNS |
| M3 | Whether Lima runs correctly as another macOS user with its own `LIMA_HOME` | Create nothing on the host: read Lima docs/source for vz requirements (entitlements are per-binary, not per-user) | H1 feasibility |
| M4 | That pf `user` rules apply to locally-destined traffic on lo0 and to IPv6 | **Privileged** — part of P6.10c | H1 effectiveness |
| M5 | Two capsules: guest A → guest B (each VM's user network address, and B's forwarded SSH port on the host) | Two disposable capsules, `check-capsule-lan` extended | N5 |
| M6 | Reboot / `pfctl -d` / anchor flush while a capsule runs | **Privileged** — P6.10c | N8 |

M1, M2 and M5 need only the existing Capsule Runtime, disposable capsules and host commands already used by
`scripts/capsule-preflight` (`netstat`); they can be run under the existing Phase 5 authority once the owner agrees
host probing is in scope for this phase (the writing agent did not run them unattended).

## 6. Lockstep-side enforcement (nonprivileged code, can be built and tested now)

1. **Boundary attestation in preflight** (`capsule-preflight`, new check `host-boundary`): reads `pfctl -s info`
   / `pfctl -a com.lockstep.capsule -s rules` (read-only; does reading need root on this macOS? → M7) and compares
   the loaded rules with the expected rule text by digest; also checks the runtime is running as `_lockstep_capsule`.
   **Unattended** execution requires `host-boundary PASS`; attended runs may proceed with a recorded WARN.
2. **No silent degradation:** absent, different or unreadable rules ⇒ `FAIL host-boundary`; the listener-exception
   path is never consulted for unattended runs.
3. **Periodic re-attestation** during a run (at each role invocation boundary): a removed boundary halts the
   transaction at the next safe boundary as `host-boundary-lost` (a typed halt, nothing replayed).
4. **Fixtures:** deterministic `pfctl` output fixtures (rules present / absent / altered / pf disabled / command
   fails) for a model-free check `scripts/lib/check-host-boundary`, in the style of `check-capsule-lan`.
5. **Image provenance:** `lima-capsule.yaml` gains a pinned dated image URL with Lima's `digest: sha256:…`
   (Lima verifies it on download). New capsules only; existing capsules keep their recorded configuration and are
   never reprovisioned. A mismatch fails provisioning (`image-digest-mismatch`). The digest must be taken from
   Ubuntu's signed `SHA256SUMS` for a chosen release date — not fetched unattended here (**BLOCKED** on that
   choice, see §7 item 5).

## 7. D6-SEC — the narrow request (to send once M1–M3 are measured)

1. **Create** an unprivileged macOS user `_lockstep_capsule` (no login shell, no home in `/Users`), owned
   directory for its `LIMA_HOME` under Lockstep's state.
2. **Install** `/etc/pf.anchors/com.lockstep.capsule` (§4, with this Mac's resolvers), one `anchor` line in
   `/etc/pf.conf`, and a launchd daemon that runs `pfctl -E -f /etc/pf.conf` at boot.
3. **Effects on existing services:** none for the owner's own processes (rules match only `_lockstep_capsule`);
   capsules lose access to every host address and private range except DNS. Existing capsules (`brigid1`, `brigidv`)
   keep running under the owner's user until explicitly migrated (separate, nondestructive step).
4. **Inspect:** `sudo pfctl -a com.lockstep.capsule -s rules`; `sudo pfctl -s info`. **Remove/roll back:** delete
   the anchor line and file, `sudo pfctl -f /etc/pf.conf`, unload the launchd daemon, delete the user.
5. **Image pin:** choose an Ubuntu 24.04 cloud-image release date to pin (or let the writing agent fetch the
   official `SHA256SUMS` for the latest one, a single public HTTPS read).
6. **Negative controls (P6.10c):** host LAN service reachable before / refused after; a listener started after
   guest launch refused; guest root (`iptables -F`, route changes, raw sockets) cannot reach it; public downloads,
   guest Docker pulls and Compose still work; two capsules cannot reach each other; reboot and `pfctl -d` make
   preflight fail and unattended runs refuse to start.
7. **If the policy is absent after reboot:** unattended execution refuses to start (`host-boundary` FAIL); attended
   runs show a WARN; nothing falls back to the listener exception.

Until D6-SEC is granted and P6.10c passes, unattended Caesura execution stays **BLOCKED** (handoff §15, §17.4).
