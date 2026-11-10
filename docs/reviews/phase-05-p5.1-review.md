# Phase 5 / P5.1: independent review and dispositions

- **Reviewed:** the P5.1 commit on `phase-5`: Dev Capsule architecture, capsule bridge, Capsule Runtime and the
  typed vocabulary.
- **Reviewer:** an independent, read-only agent. It changed and ran nothing.
- **Dispositions by:** the Implementer. Every HIGH and MEDIUM finding was fixed or explicitly deferred.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | `exec_readonly` ran a normal command in the Engineer's live VM; guest sudo or Docker made it mutating. | **Fixed.** Read-only roles get `read`, `list` and `search` only (runtime binding, bridge, `roleOperations`, `guest-exec`). A command for read-only roles waits for a separate review capsule. Unit test V3 updated. |
| 2 | HIGH | The world-writable channel allowed result forging, symlink writes through `results/.N.tmp`, and a check-then-use race on requests. | **Fixed.** `results/` is mounted **read-only** into the provider's container, and results are made in a private directory and renamed in. Each request is first moved into the invocation's private directory, then checked (`-L`, `-f`, size), so a swap after the check is impossible. New check T14: a symlinked request naming a host file is refused, and the file's content goes nowhere. |
| 3 | HIGH | guest-exec's state at `/run/lockstep-exec` is not writable by the guest user, so `exec` and cancel break on a real VM. | **Fixed.** State is `~/.cache/lockstep-exec` (the same user runs the call and its cancel). Checked on the VM by B1–B3. |
| 4 | HIGH | `run` printed guest output before the runtime's reply (forgeable). The import `head` came from the guest. | **Fixed.** Guest output goes only to a file named in the reply. `import` reports `head=` from the host's bundle and `guest-head=` separately. The `base` snapshot policy (§8) stays "before any Engineer guest-root change". |
| 5 | HIGH | Host-loopback reachability was not blocked, and D4 could pass vacuously. | **Test fixed:** a host-side precondition that the probe answers; raw TCP connects to 6 targets, each asserted; a positive control that the probe ran. **The boundary itself is measured on the VM, not assumed** (`qualification.md`). |
| 6 | MED | The guest re-parsed the whole request, so a duplicate `"op"` key could smuggle `write` past the host's `read` check. | **Fixed.** The host passes `--op`, and guest-exec refuses a mismatch and rejects duplicate keys. New check T13. |
| 7 | MED | Two `serve` processes per invocation; R2 did not simulate a crash. | **Fixed.** A PID lock per invocation (stale lock recovered). Recovery runs under the lock. R2 uses `kill -9`. New check T15. |
| 8 | MED | A timeout killed a subshell, not the transport; `rc` was `head`'s. | **Fixed.** The transport is started directly (`$!` is `limactl` or `docker exec`), and output is capped after it ends. |
| 9 | MED | Bind check-then-create race; `close` leaves guest daemons; the limit was not capped. | **Partly fixed:** a per-project bind lock, and the limit is capped at the profile's. **Deferred to P5.9:** ending the guest processes of a closed Implementer (restart or process sweep). The engine's own single-writer rule still holds; the gap is daemons outliving a binding inside the same capsule. |
| 10 | MED | The bridge restarted `seq` at 1 and could return a stale result. | **Fixed.** `seq` starts above every existing file; requests are created with `O_EXCL\|O_NOFOLLOW`; an already-answered sequence is an error. |
| 11 | MED | The audit missed Lima's merged `_config/override.yaml` and `default.yaml`. | **Fixed.** Either file present refuses the start (`audit-lima-overrides-present`). |
| 12 | LOW | V4's substring test matched comments. | **Fixed.** Code lines only, at a word boundary. |
| 13 | LOW | T7 is trivially true on the fixture. | Accepted. On the fixture, T7 shows routing; the VM's own absence of credentials is D2/D3, and B4 holds by construction. |
| 14 | LOW | `hostResolver` gives the guest the host's DNS. | **Deferred** (network policy, P5.4 follow-up): recorded as a limitation. |
| 15 | LOW | Escaped grandchildren can hold `communicate()` until the deadline. | Accepted: bounded by the deadline, and the process group is killed. |

Re-run after the fixes: `check-capsule-bridge` 34/34 (`evidence/p5.1-bridge-r2/`); `lockstep-capsule` 18/18.
