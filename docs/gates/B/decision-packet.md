# Gate B — decision packet

For the human owner. This packet links the canonical artifacts and asks only for your
decisions. Nothing in it is decided, and Gate B is not recorded as accepted.

## What to decide

1. **Gate B** for `docs/gates/B/gate-report.md`, revision **r1**,
   SHA-256 **`adba95d1b955935234e0e4975e51069d5cdbd44162728c8da4f4340144dadeb8`**, tested commit
   **`7ecb5ac`**. A decision against another revision or digest does not apply to this report.
2. **Acceptance of P2.1–P2.9** and `lockstep open`, each at the commit in report §3. The
   default-browser check of `lockstep open` is still yours to do.
3. **Effect-key rule** (report §5.2). Choose one:
   - (a) keep it as built: a key is one logical effect per Work Order, and a second intent with
     that key never runs beside a live one;
   - (b) also refuse such an intent when it is created. This would change the frozen test
     `RemediationReviewTest.hs` (N2) and needs the exact diff approved.
4. **Unacknowledged abandonment** (report §5.3). Choose one:
   - (a) accept that it fails closed;
   - (b) add a Human-only `effects acknowledge-abandon OP` now;
   - (c) carry it to Phase 3.
5. **Authority by command** (report §5.1): accept for Phase 2, carried to Phase 3.
6. **Your operator installation** (report §5.8). Your service is stopped, your database is at
   schema 5, and `.local/install` holds a rebuild of `6c2851d`. When, and whether, to back up,
   migrate to 12 and install the accepted commit is yours to decide. Nothing has been done to
   it.

## Where things stand

- Machine summary: **`PASSED`**, from B1 run 3 at `7ecb5ac`: 20/20 required criteria. It is
  evidence, not acceptance.
- The fresh-clone check inside B1 and the Linux clean-clone check, both at `7ecb5ac`: all
  steps PASSED, 678/678 unit and 181/181 integration. These cover real PostgreSQL, real
  crashes, overlapping worker processes, headless Chromium, and backup and restore.
- Independent read-only reviews (agents, not humans): five rounds. **No HIGH or MEDIUM finding
  remains open.** The last round found 2 LOW: one fixed, one a recorded limitation.
- Amendments you approved and that are applied: R-P2.9-1, R-P2.9-2, R-P2.9-3 and R-P2.9-4.
  Every frozen digest was re-verified on 2026-10-20 (report §2.1).
- Lapses, disclosed:
  - one freeze record was withdrawn before any run;
  - one frozen assertion contradicted its fixture (R-P2.9-4);
  - one overwritten log held only a format failure.
- Phase 3 has not begun.

## Canonical artifacts

| Artifact | Path |
|---|---|
| Gate B report | `docs/gates/B/gate-report.md` |
| B1 evidence, run 3 (runs 1 and 2 kept) | `docs/gates/B/evidence/b1-run3/` (`SHA256SUMS`) |
| Reviews and dispositions | `docs/gates/B/review.md`, `docs/gates/B/review-remediation.md` |
| B1 Contract and amendments | `docs/gates/P2.9/contract.md` §6; `r-p2.9-*-amendment-request.md` |
| Remediation Contract, freezes and evidence | `docs/gates/P2.9/r1-contract.md`; `docs/gates/P2.9/r1-evidence/` |
| Sub-phase records | `docs/gates/P2.1/` … `docs/gates/P2.8/`, `docs/gates/P2-open/` |
| Operator guide | `docs/OPERATOR_GUIDE.md` §6 |
| Consolidated Phase 2 retrospective | `.local/retros/retro-02.md` (local, gitignored) |

## Your decision (to be filled in by you)

| Field | Value |
|---|---|
| Gate B (report r1, `adba95d1…`) | |
| P2.1 / P2.2 / `lockstep open` / P2.3 / P2.4 / P2.5 / P2.6 / P2.7 / P2.8 / P2.9 | |
| Effect-key rule (3a / 3b) | |
| Unacknowledged abandonment (4a / 4b / 4c) | |
| Authority by command | |
| Operator installation | |
| Decided by / at | |
