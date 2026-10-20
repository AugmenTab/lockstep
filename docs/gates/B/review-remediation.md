# Gate B — second independent read-only review (the remediation) and dispositions

- Reviewer: a separate **read-only** reviewer agent of the same model family as the writer. It
  had no edit, write, build, Docker or network use. **This is not a human review.**
- Scope: `git diff 6b5cf92..de3ebc5 -- src app scripts test`, against C-P2.9-R1, the first
  review's 16 findings, the owner's six carry requirements, and DG-04.
- Date: 2026-10-20. Result: **2 HIGH**, 2 MEDIUM, 6 LOW, 2 INFO.
- The HIGH findings are latent with today's sandbox: they need a real class-B destination whose
  keys expire, or a carry. They are still paths the owner's requirements say must be closed.
- Dispositions by the writing agent. The fixes are C-P2.9-R1 §4.2 (addendum N1–N8).

| # | Sev. | Finding (summary) | Disposition |
|---|---|---|---|
| 1 | HIGH | The class-B key check runs only at recovery. A lapsed claim left after a recovery, or a carried claimed intent, is re-dispatched later with no key check. | **Fix N1**: every dispatch of an idempotent intent that was dispatched before needs its key guarantee. Otherwise the intent becomes unknown (`dispatch-interrupted: idempotency key may have expired`), the order halts, and nothing is sent. The carry's key check applies to every carryable state. |
| 2 | HIGH | A carry is not checked against the target activation's own intents with the same effect key: two operation ids for one effect. | **Fix N2**: `carry-conflict` when the target activation has an intent with the same effect key that is not abandoned. |
| 3 | MEDIUM | A carry states no expected activation, so a stale carry binds silently. | **Fix N3**: `carryIntentChecked` takes the expected source and target activations (`stale-carry`). The CLI `effects carry` requires `--from-activation` and `--to-activation`. The frozen `carryIntent` stays the unconditional library form. |
| 4 | MEDIUM | A human "attest not applied" can be carried without a duplication-risk acknowledgment. | **Fix N4**: carrying a human-attested not-applied intent needs the acknowledgment (`duplication-risk-not-acknowledged`; CLI `--acknowledge-duplication-risk`). |
| 5 | LOW (latent) | `concludeIntent` and `applyLookup` can return a non-integrity refusal after writing. | **Fix N5**: those unreachable branches are integrity failures, so they roll back. |
| 6 | LOW | Recovery of a superseded intent says "subject not active", and halts the new activation. | **Fix N6**: reason `dispatch-interrupted: activation superseded`; the current activation is not halted. |
| 7 | LOW | The unchecked C-P2.5 intent functions are not marked in code. | **Fix N7**: documented in the module as test-level API; no product caller. |
| 8 | LOW | The abandonment halt is recorded as the Supervisor's. | **Fix N8**: recorded as the Human's. |
| 9 | LOW | Migration 0012 gives pre-migration intents activation 1. | **Recorded as a limitation.** No pre-migration intents exist outside Phase 2 test databases: the operator database is at schema 5. Such an intent is fenced and needs a carry, which is safe. Adding migration 0013 for this was judged not worth a schema change. |
| 10 | LOW | (a) A bare session value would not be found by B1's scan. (b) `LOCKSTEP_SERVICE_INSTALL_DIR` is not validated. | (a) **Recorded**: no Lockstep output prints the cookie, and a generic 43-character pattern would match inside the hex digests B1 records. (b) **Fixed**: only a relative path without quotes or spaces is accepted. |
| 11 | INFO | Some checks prove less than they appear to (the concurrent read; B1-15 and B1-18 can be `idle`). | **Recorded** in the Gate B report. The refusal-under-overlap proof is the integration regression. |
| 12 | INFO | Queryable recoveries wait for `reconcile-once`. | **Recorded** in the operator guide note. |
