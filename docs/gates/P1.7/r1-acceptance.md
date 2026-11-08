# C-P1.7-R1 acceptance record (browser-form remediation)

- Contract: `C-P1.7-R1@v1` (`r1-contract.md`), frozen in `2410593`; tests unchanged since
- Authority: the Planner's Gate A decision (Option A) and the owner's R-P1.3-1 approval
  (`docs/gates/A/r2/browser-forms-regression.md`)
- **Tested commit: `6c2851d40a13be9ce08c97e692e30575b7b7d6e2`** (`v2`, clean; fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: macOS arm64, OrbStack (Docker Engine 29.4.0); dev image with Chromium
  155.0.8059.79 and Python 3.11.2 (test tooling only)
- Executed by: manual agent session (writing agent / Implementer), 2026-10-18
- Machine summary: `PASSED`. **This is not acceptance.**

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-R1-01@v1` The regression is reproduced by a real browser before the fix | frozen `BrowserFormTest` against the unfixed binary | rename, queue, sign-out sent with `Origin: null` and refused; negatives already refused | as expected | PASSED | `r1-evidence/prefreeze-integration-against-current-binary.log` |
| `AC-R1-02@v1` Served forms work in a real browser after the fix (R1) | `BrowserFormTest` in the fresh-clone suite and the Linux clone | exact Origin, origin-only Referer, 303s, state changed in PostgreSQL | as expected (259 unit / 67 integration, both environments) | PASSED | `docs/gates/A/r2/evidence/a1/check-fresh-clone.log`; `r1-evidence/check-linux-clone.log` |
| `AC-R1-03@v1` The guard is not weakened | `BrowserFormTest` negatives; review | cross-origin, `null`-Origin and tampered-CSRF refused, nothing stored; guard source unchanged | as expected | PASSED | same; `docs/gates/A/r2/review-remediation.md` |
| `AC-R1-04@v1` Only authorized frozen-test changes | digests; diff against the authorized amendment | 39/39 OK; R-P1.3-1 byte-identical; runners additive | as expected | PASSED | `r1-evidence/sha-and-diff-checks.log` |
| `AC-R1-05@v1` A1 uses the real browser for the UI command (R5) | `scripts/a1` A1-06/06c | browser sign-in, form rename, sign-out; durable, attributed to `browser-session` | 18/18 A1 checks | PASSED | `docs/gates/A/r2/evidence/a1/` |
| `AC-R1-06@v1` Records corrected (R7) | inspection | corrections appended to the P1.4–P1.6 records; r1 kept; r2 issued | done | PASSED | `docs/gates/P1.4–P1.6/acceptance.md`; `docs/gates/A/r2/gate-report.md` |
| `AC-R1-07@v1` The shipped binary does not depend on the new image tooling (R2) | `ldd` of the installed binary; licenses | no Chromium/Python/GUI libraries; inventory unchanged | as expected | PASSED | `r1-evidence/ldd-installed-binary.txt`; `r1-evidence/licenses.txt` |

## Deviations and notes

1. **R5 as written is only partly met** (review finding 1):
   - The form-duplicate check is impossible by design (R6).
   - The browser stale check is not automated: it would need the frozen driver extended. It is
     added to the owner's demonstration instead (r2 §4 step 5b).
   - A1-08 still checks the server's stale refusal at HTTP level, and is labelled as such.
2. **R3:** responses are taken from `responseReceived` and `redirectResponse`, not
   `responseReceivedExtraInfo`. Hop pairing is positional. Both fail safe (review findings 2–3).
3. **History:** A1 run 1 at `f1b6e1c` failed because `docker run` lacked `-i`; it is kept in
   `docs/gates/A/r2/evidence/a1-history/` and was fixed in `6c2851d`. The demonstration service on
   port 8010 was stopped before the remediation. A1 databases `lockstep_a1_20261018t192429z` and
   `…193229z` are kept, with all sessions revoked.
4. The R1 review and its dispositions: `docs/gates/A/r2/review-remediation.md`.

## Decision

| Field | Value |
|---|---|
| C-P1.7-R1 | **`VERIFIED — awaiting human acceptance`** at `6c2851d40a13be9ce08c97e692e30575b7b7d6e2` |
| Recorded by | manual agent session (writing agent / Implementer), 2026-10-18. Not an acceptance. |

## Human acceptance (2026-10-18)

The human owner accepted C-P1.7-R1 with P1.3–P1.7 and Gate A r2. Recorded by the writing agent
(Implementer) at the owner's instruction; this is the owner's decision, not the agent's. Owner's
words, verbatim: "**P1.3–P1.7: ACCEPTED**, including the authorized C-P1.7-R1 remediation,
against their documented tested commits and Gate A r2 qualification evidence."

| Field | Value |
|---|---|
| C-P1.7-R1 | **ACCEPTED** |
| Tested commit | `6c2851d40a13be9ce08c97e692e30575b7b7d6e2` |
| Deviation 1 (R5 partly met) | accepted within its recorded scope: the browser stale check was done in the owner's demonstration (step 5b), which the owner passed |
| Decided by | the human owner (operator), 2026-10-18 (`docs/gates/A/r2/decision-packet.md`) |
