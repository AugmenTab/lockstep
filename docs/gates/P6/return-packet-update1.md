# Phase 6 — return packet for update 1 (§8)

- Branch: `phase-6` (local; nothing pushed). Writer: the single Implementer. Nothing here is accepted on the
  owner's behalf: every subphase below is **locally qualified, owner acceptance pending**.
- Authority: `.local/plans/phase-06_update1.md`. No live provider call, no Caesura, no remote push, no privileged
  host operation, no host probing was performed.
- Date: 2026-11-15.

## 1. P6.3 all-green regression results

| Revision | Result | Log |
|---|---|---|
| `fd35945` (A-P6.3-1 applied on the R-P6.3 remediation `2d65a1f`) | format, lint/static, build, unit **950/950**, no-live-model guard, integration **622/622**, backup/restore — all PASSED | `.local/evals/phase-06/a631-full-check.log` |

Record: `docs/gates/P6.3/review.md` ("After A-P6.3-1"). Every later full check below re-ran all P6.3 cases.

## 2. DG-08 — recorded decision and frozen-plan semantics

`docs/gates/DG-08/decision.md`: **Option 2** — an immutable, digest-bound approved Master Plan outline with bounded
just-in-time Contract elaboration. Frozen by an approved revision: source PRD/architecture identities (SHA-256),
project and repository ownership, stable work identities and the typed dependency graph, required outputs and
acceptance criteria, risk and external-effect classes, execution authority/limits/mandatory verification, the exact
revision and digest. Recorded readings the owner may change: unit phase/subphase placement and owner priorities are
frozen (stricter reading); the effective Profile per unit and the provisional-edge policy are treated as execution
authority. **The separate local Phase signoff (packet §3.7) is left OPEN** — not implemented, not decided.

## 3. Amendment evidence

- **A-P6.3-1** (principal labels, authorized update 1 §2): `docs/gates/P6.3/amendments.md`; applied in `fd35945`.
- **A-P6.4-1** (the C-P4.1 ban on `plan`/`phase` column names, narrowed; authorized update 1 §4):
  `docs/gates/P6.4/amendments.md`; applied in `df8507e`.

## 4. P6.4–P6.9 implementation and independent-review evidence

Each subphase: tests frozen RED (digests in its `contract.md` §5) → implementation → full check → an independent
read-only review → remediation tests frozen RED against the implementation → remediation → full check. Reviews,
dispositions and limitations: `docs/gates/P6.N/{review,amendments}.md`.

| Subphase | Freeze → implementation → remediation | Final full check (all steps PASSED) |
|---|---|---|
| P6.4 Master Plan, typed DAG, digest-bound approval, reconciliation | `df8507e` → `4c2ad25` → `b32da66` | unit 985, integration 639 |
| P6.5 Continuous deterministic scheduling | `a510f73` → `58c9ee4` → `1753832` | unit 1001, integration 654 |
| P6.6 Greenfield/brownfield Profile parity | `54be30a` → `e28bf89` → `c526e18` + `ecd1e66` | unit 1029, integration 667 (second run; the first had one C-P3.1 control-helper timing flake that passed alone) |
| P6.7 Provisional progression, invalidation, rework | `3ca8c4b` → `f3b3c71` → `ee3b73a` | unit 1043, integration 676 |
| P6.8 Evidence-linked summary (no model Scribe) | `2342245` → `9c5fb65` → `543f9d6` | unit 1062, integration 687 |
| P6.9 Human-controlled improvement proposals | `7742f51` → `a8e74d7` → `ef3c64a` | unit 1078, integration 699 |

Disclosure (from P6.6 on): when a RED baseline stopped at the first missing piece, the frozen tests were first tried
against a draft implementation, the stubs restored and the baseline re-taken; every such trial and any fixture
correction is recorded in the contract §5 or the review.

## 5. P6.10 — measurements and the D6-SEC recommendation

- **M1–M3: NOT RUN.** Update 1 §6 authorizes them as *attended* measurements; they were not run unattended. The
  procedure for the attended session is §5.2.
- **Design corrected** before D6-SEC (update 1 §6): pf `user` predicates apply only to TCP/UDP, so the ICMP rule was
  removed from the user-scoped anchor and ICMP became measurement M2b with an explicit owner choice
  (`docs/gates/P6.10/design.md` §4, `b9cef5d`).
- **P6.10b (nonprivileged safeguards), implemented and reviewed** (`docs/gates/P6.10/contract-b.md`, `review-b.md`,
  `amendments-b.md`). The pieces:
  - `scripts/capsule/host-boundary` reads pf's state read-only (no sudo) and compares it with the owner's recorded
    expectation.
  - `scripts/capsule-preflight --unattended` fails closed; attended preflights get a WARN.
  - The preflight checks that each running hostagent runs under the boundary's uid.
  - No fallback to the LAN exception.
  - Model-free checks run in the lint step against a stand-in `pfctl`: `check-host-boundary` 42/42 and
    `check-host-boundary-review` 9/9.
  - Commits: freeze `32e7735`, implementation `74644a8` (full check passed: unit 1078,
    integration 699), remediation `6b0a6c6` (full check passed: unit 1078, integration 699; both host-boundary checks in the lint
    step).
  - **Not sufficient yet for unattended runs.** The review found policy changes the attestation cannot see: table
    contents, an anchor that is loaded but not reached, `set skip on lo0`, and the rules' uid. These are P6.10c work
    and need amendments of the frozen check (pfctl commands beyond the two it allows). Re-attestation during a run
    is also P6.10c.

### 5.1 D6-SEC — recommendation, revised

Unchanged in substance from `design.md` §7, pending M1–M3: H1 (a dedicated unprivileged `_lockstep_capsule` user
running the Capsule Runtime, plus the pf anchor `com.lockstep.capsule`, TCP/UDP only). Revisions:

1. **ICMP:** decide after M2b — no rule if the hostagent does not relay guest ICMP; otherwise either a
   non-user-scoped echo block to private ranges (also affects the owner's own pings) or a recorded residual risk.
2. **Attestation readability (M7):** if `pfctl -s info` / `-s rules` need root on this macOS, every attestation is
   `pf-unreadable` and unattended runs cannot start (fail closed). D6-SEC should then also install a root-owned,
   read-only status export (a launchd job writing the anchor's rules and pf's status to a root-owned file the
   attestation reads instead), or accept that unattended runs require it.
3. **Recording:** after installation the owner writes `HELPER-STATE/capsule/host-boundary` with the digest the
   preflight prints.
4. **P6.10c attestation scope (from the P6.10b review):** the D6-SEC grant should also authorize the attestation
   to read the anchor's tables (`-s Tables`, `-T show`), the main ruleset (`-s rules`) and the interface skip flags
   (`-s Interfaces -v`); pin `/sbin/pfctl`; and require the rules' `user =` uid to be `capsule-user`'s. These need
   the frozen C-P6.10b check to be amended (owner authority).
5. **Rollback** as in `design.md` §7 item 4 (remove the anchor line and file, reload pf, unload the launchd job,
   delete the user; the attestation then reports `anchor-absent`/`pf-…` and unattended runs refuse to start).

No H1/H2 mechanism is approved; nothing was installed.

### 5.2 Attended M1–M3 procedure (for the owner's session)

All read-only on the host, with the existing Phase 5 disposable capsules (`check-capsule-vm --keep`):

- **M1** — guest → host LAN: on the host, a disposable listener on the LAN address (as `check-capsule-lan` G does);
  from the guest, `bash -c 'exec 3<>/dev/tcp/<lan>/<port>; sleep 20'`; meanwhile on the host
  `lsof -nP -iTCP@<lan>:<port>` and `ps -o user=,pid=,comm= -p <pid>`. Records: the owning process and its user.
- **M2** — guest → public TCP (an HTTPS fetch held open), UDP (`dig @1.1.1.1`), guest DNS (`getent hosts`), with the
  same `lsof`. **M2b** — `ping -c 1 <lan>` and `ping -c 1 <router>` from the guest; `lsof -nP -c limactl` /
  `-c hostagent` during it (socket type, if any).
- **M3** — reading only: Lima's documentation/source on running `vz` instances under another macOS user with its own
  `LIMA_HOME` (entitlements are per binary).

## 6. Remaining blockers, uncertainties, next work

**Blocked on owner decisions:**

- Owner acceptance of P6.3–P6.9 and P6.10b (the Implementer accepts nothing).
- **D6-SEC** (after attended M1–M3): unattended Caesura execution and P6.10c stay BLOCKED until it is granted and
  P6.10c passes.
- **P6.11 model-free Gate D: NOT STARTED.** Its prerequisites are not met: D-11 and the adversarial case "host
  boundary removed during unattended execution" need the installed boundary (P6.10c), and the suite runs on real
  capsules. Stories D-01–D-10 do not depend on the boundary and could be built first if the owner wants.
- Open owner questions: DG-08 local Phase signoff; OQ-P6.9-1 (amend frozen C-P6.9 tests so commit evidence must be
  recorded and non-catalog Profile targets are refused); OQ-P6.9-2 (may a stale proposal still be rejected).
- Image provenance pin (design §6 item 5): choose an Ubuntu 24.04 cloud-image date.

**Recorded limitations (not blockers):** see each `amendments.md`/`review.md`. The main ones are:

- P6.5: a prerequisite reached only by an untyped dependency builds on the person's checkout.
- P6.6: `lockstep-engineering` is not on the checks page's list (pinned by a frozen test), and floors are checked
  for presence only.
- P6.7: older halt requests stay open after an invalidation, and a person's first hand-over of a plan unit runs as
  a bug fix.
- P6.8: usage is read from a 2000-character tail, and reads are per task.
- P6.9: commit evidence is checked for form only, and a proposal for a non-catalog Profile cannot be decided.
- P6.10b: re-attestation during a run is not built (it is P6.10c work).

**Next dependency-ready work:** the attended M1–M3 session; then D6-SEC; then P6.10c (install, negative controls,
re-attestation during a run); then P6.11. Gate D acceptance remains the owner's.
