> **Superseded (2026-10-18).** The human demonstration against report r1 failed at step 4 (browser forms refused). See `docs/gates/A/r2/decision-packet.md` and `docs/gates/A/r2/gate-report.md`. This packet and report r1 are kept unchanged below as evidence.

# Gate A — decision packet

For the human owner. This packet links the canonical artifacts and asks only for your
decisions. Nothing in it is decided.

## What to decide

1. **Gate A** for report `docs/gates/A/gate-report.md`, revision **r1**,
   SHA-256 **`efee1118ad12a6221cd096793c3ca7889519da5c2ae1500f137bb0f53e705524`**, tested
   commit **`de8afa3`**. A decision against another revision or digest does not apply to this
   report (VISUAL_EVIDENCE_CONTRACT §7).
2. **Acceptance of P1.3–P1.7**, each at its own tested commit (report §2). P1.1 and P1.2 are
   already accepted.
3. **Session-cookie limitation** (report §3.1; review finding 1): (a) accept for Phase 1;
   (b) `Path=/operator` and a shorter lifetime; (c) a dedicated loopback hostname, which
   changes D-1a.
4. **Human-operated demonstration** (report §4, criterion AC-A1-18): about 10 minutes in your
   own browser. It is `NOT_RUN` until you do it, and the machine summary stays `NOT_RUN` until
   then.

## Where things stand

- Machine summary: **`NOT_RUN`**, only because of AC-A1-18. All 21 other required criteria are
  `PASSED` with evidence. This summary is not acceptance.
- A1 scripted run: 17/17 checks at `de8afa3` (`evidence/a1/`; earlier runs and why each was
  superseded: `evidence/a1-history/README.md`).
- Independent read-only review (an agent, not a human): no HIGH findings. 3 of 4 MEDIUM fixed;
  the fourth is item 3 above (`review.md`).
- Defects found and fixed on the way to Gate A, disclosed in the report and P1.7 record:
  unescaped form `value` attributes (a Brigid 0.4 behaviour); raw session cookies in A1's own
  logs (sessions revoked, history redacted).
- Phase 2 has not started.

## Canonical artifacts

| Artifact | Path |
|---|---|
| Gate A report | `docs/gates/A/gate-report.md` |
| Review and dispositions | `docs/gates/A/review.md` |
| A1 evidence | `docs/gates/A/evidence/a1/` (`SHA256SUMS`) |
| Sub-phase records | `docs/gates/P1.1/` … `docs/gates/P1.7/` (`acceptance.md`, `contract.md`, `evidence/`) |
| Operator guide | `docs/OPERATOR_GUIDE.md` |
| Decision register | `docs/governance/DECISION_REGISTER.md` |
| Whole-phase retrospective | `.local/retros/retro-01.md` (local, gitignored) |

## Your decision (to be filled in by you)

| Field | Value |
|---|---|
| Gate A (report r1, `efee1118…`) | |
| P1.3 / P1.4 / P1.5 / P1.6 / P1.7 | |
| Session-cookie limitation | |
| Human demonstration: date, result, anything unexpected | |
| Decided by / at | |
