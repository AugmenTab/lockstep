# Escalation: guest-to-host-loopback reachability (P5.4 D4)

- **For:** the owner. **Raised:** 2026-11-10 by the Implementer, under handoff §19 ("escalate when the VM cannot be
  isolated from protected host services").
- **Status:** OPEN. This is the smallest decision Phase 5 needs before a live Brigid run. All other P5.2–P5.4 checks
  pass on a real VM; work on P5.5+ continues meanwhile (model-free only).

## Finding (measured, not inferred)

From inside a Dev Capsule (Lima 2.3.0, VZ, Ubuntu 24.04 arm64, the audited `scripts/capsule/lima-capsule.yaml`), a
TCP connection to `192.168.5.2:<port>` or `host.lima.internal:<port>` **reaches a service listening on the host's
`127.0.0.1:<port>`**.

The probe was a busybox HTTP server published on the host's `127.0.0.1:18765`. Before the guest-side test, the
check confirmed from the host that the probe answered (HTTP 404). Evidence:
`evidence/p5.2-p5.4-vm/results.txt` (D4 lines) and `isolation.out` (`tcp 192.168.5.2:18765 open`). In the same run,
192.168.5.2 ports 2375, 5432, 8000 and 22 were closed, because nothing listened there on the host.

Cause: Lima's user-mode network (gvisor-tap-vsock, "usernet") is always attached for VZ, and it is also how the
host agent reaches the guest's SSH. It translates the gateway address 192.168.5.2 to the **host's loopback**. The
connection is made by the host-agent process, which runs as the owner's user. No Lima setting turns that
translation off. A firewall inside the guest does not count, because guest root controls it.

Consequence: any service bound to the owner's loopback, unauthenticated or not, is reachable by untrusted guest
code. On this Mac today (`lsof -iTCP -sTCP:LISTEN`), that includes OrbStack's loopback listeners (32222, 59514) and,
whenever they run, Lockstep's own service and its PostgreSQL port, if published on loopback. Separately, several
OrbStack-published container ports listen on **all** interfaces (4444, 5984, 6984, 7900, 8300, 8310, 8320, 8780,
8781, 9300). Any network peer reaches those, a capsule included, through its ordinary outbound path.

What is **not** affected (measured): no host file is visible (`mounts: []`, `/Users` absent), no SSH agent is
forwarded, the host's Docker socket is not reachable (the guest's Docker is its own), and the provider credential is
not in the guest at all (B4: the CLI runs in a container on the host with no tools; the capsule only receives
tool calls).

## Options (the owner's decision)

| # | Option | Effect | Cost |
|---|---|---|---|
| A | **A dedicated macOS user for the Capsule Runtime, plus a `pf` anchor** blocking loopback connections owned by that user, except the agent's own SSH forward | A real boundary outside the guest | One-time admin setup (sudo) by the owner; then a qualification run I can do |
| B | **Accept for Phase 5, with compensating controls:** Lockstep's own services require authentication (they do); nothing secret listens unauthenticated on loopback while a capsule runs; preflight lists loopback listeners and refuses to start a live session when an unexpected one is present | Brigid can proceed; the residual risk is recorded | None now; the risk is accepted in writing |
| C | **Another VM backend** with a network that does not map the host (e.g. QEMU `restrict=on` with a separate SSH path, or socket_vmnet without usernet) | Removes the path | New backend work and a host install; outside tonight's authority |

The Implementer recommends **B for Gate VM-1**, with the preflight refusal implemented, and **A as the follow-up**.
B keeps the phase moving under a recorded, bounded risk. A is the durable fix but needs the owner's admin action.
