# Gate A — decision packet (r2)

For the human owner. This packet replaces `docs/gates/A/decision-packet.md`, which was for report
r1 and is superseded by the failed demonstration. Nothing here is decided.

## What to decide

1. **Gate A** for report `docs/gates/A/r2/gate-report.md`, revision **r2**, SHA-256
   **`33c8d26a0b7a01696fc1e2b4c3f2541fd7062a2d18f60616cc0da895520feaef`**, tested commit
   **`6c2851d`**. A decision against another revision or digest does not apply.
2. **Acceptance of P1.3–P1.7** and the **C-P1.7-R1** remediation, each at its tested commit
   (report §2; `docs/gates/P1.7/r1-acceptance.md`).
3. **Session-cookie limitation** (report §3.1): (a) accept for Phase 1; (b) `Path=/operator` and
   a shorter lifetime; (c) a dedicated loopback hostname, which changes D-1a.
4. **Human-operated demonstration** (report §4, AC-A1-18@v2): about 10 minutes in your own
   browser, now on port 8010 and with the corrected replay and new browser stale steps. It is
   `NOT_RUN` until you do it.

## What changed since r1

- **Your r1 demonstration failed at step 4.** The operator pages sent
  `Referrer-Policy: no-referrer`, so browsers sent `Origin: null`, which the strict guard refused.
- **Fix (Planner Option A, `c5915e3`):** `Referrer-Policy: origin` on `/operator` and
  `/operator/jobs/new`. The guard is unchanged; there is no `null` exception.
- **New frozen real-browser test:** headless Chromium submits the served rename, queue and
  sign-out forms, and the state is checked in PostgreSQL. Cross-origin, `null`-Origin and
  tampered-CSRF submissions are refused. Before the fix, the test reproduced your failure.
- **R-P1.3-1** applied byte for byte. **A1** now drives the real form in a browser: 18/18 at
  `6c2851d`. Records P1.4–P1.6 are corrected; r1 is kept.
- **Independent review** of the remediation: no HIGH findings. One MEDIUM: R5 is only partly met;
  the browser stale check is added to your demonstration (step 5b).

## Canonical artifacts

| Artifact | Path |
|---|---|
| Gate A report r2 | `docs/gates/A/r2/gate-report.md` |
| Regression report and decisions | `docs/gates/A/r2/browser-forms-regression.md` |
| Remediation Contract and record | `docs/gates/P1.7/r1-contract.md`, `r1-acceptance.md`, `r1-evidence/` |
| Reviews | `docs/gates/A/review.md`; `docs/gates/A/r2/review-remediation.md` |
| A1 evidence | `docs/gates/A/r2/evidence/a1/` (superseded runs: `a1-history/`) |
| Superseded report r1 | `docs/gates/A/gate-report.md` (sha256 `efee1118…`) |
| Operator guide | `docs/OPERATOR_GUIDE.md` |
| Retrospective | `.local/retros/retro-01.md` (local) |

## Your decision (to be filled in by you)

| Field | Value |
|---|---|
| Gate A (report r2, `33c8d26a…`) | |
| P1.3 / P1.4 / P1.5 / P1.6 / P1.7 (incl. C-P1.7-R1) | |
| Session-cookie limitation | |
| Human demonstration: date, result per step, anything unexpected | |
| Decided by / at | |
