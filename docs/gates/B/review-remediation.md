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

## 2. Third independent read-only review (of N1–N8 at `8fce278`)

- Same kind of reviewer: read-only, same model family, **not a human review**.
- Result: **no HIGH**, 2 MEDIUM, 2 LOW, INFO. It confirmed N1, N3, N5, N7 and N8, and that no
  frozen file is touched.
- Fixes: C-P2.9-R1 §4.5 (P1–P4). The tests were run before the fixes and then frozen.

| # | Sev. | Finding (summary) | Disposition |
|---|---|---|---|
| 1 | MEDIUM | A restart may create a new intent with the same effect key as an earlier activation's live intent. N6 removed the halt that used to stop the new one. Risk: one effect applied twice under two operation ids. | **Fix P1**: the new intent is never dispatched while a same-key intent is live (`effect-key-in-use`, order halted). Admission refusal was the alternative. It would change the frozen N2 test, so it is offered to the owner instead of applied. |
| 2 | MEDIUM | N4 is bypassed through the claimed state: an attested intent, claimed, fenced and re-carried, skips the acknowledgment. | **Fix P2**: an attestation record needs the acknowledgment in every carryable state. |
| 3 | LOW | The N2 conflict only looks at the target activation. | **Fix P1**: a conflict with a live same-key intent of any activation. |
| 4 | LOW | A human retry after the N1 check is accepted, then turned back into unknown: a loop. | **Fix P3**: the retry is refused with `idempotency-key-expired`. |
| 5 | INFO | The unchecked carry forms are exported; the install directory accepts `.`, `.git` and `src`. | **Fix P4**: they are documented as library forms, and the directory must lie under `.local/`. |
| 6 | INFO | N5 rolls back a settle that cannot be reached; the requirement-6 regressions sit in the earlier frozen suites. | **Recorded.** |

## 3. Fourth (final) independent read-only review (of P1–P4 at `53ee0d5` plus the approved amendments)

- Same kind of reviewer: read-only, same model family, **not a human review**.
- Result: **no HIGH**, 1 MEDIUM, 3 LOW, 3 INFO.
- It confirmed:
  - no new lock, and no deadlock;
  - every dispatch path goes through the same-key check, including the claim;
  - no self-blocking, and no hot loop;
  - P2 and P3 are correct, and P3 leaves other classes alone;
  - ownership, fencing and the carry records are unchanged.
- Fixes: C-P2.9-R1 §4.7 (F1–F4). The new tests were run before the fix, then frozen.

| # | Sev. | Finding (summary) | Disposition |
|---|---|---|---|
| 1 | MEDIUM | Abandoning a dispatched or unknown sibling frees the other same-key intent to run, with no duplication-risk acknowledgment. | **Fix F1**: a dispatched intent keeps its key after it is abandoned, until the abandonment acknowledges the risk (`effects abandon … --acknowledge-duplication-risk`; recorded in `human-abandon`). Abandoning while a lease is still held stays allowed: with the acknowledgment, the Human accepts the risk of an effect still in flight. |
| 2 | LOW | P1 makes the effect key unique per Work Order, not per (subject, revision, key) as C-P2.5 E2 has it. A settled-applied sibling blocks a later intent with the same key forever. | **Recorded as a limitation and a decision for the owner.** This is deliberate: one logical effect, one live intent. The CLI creates intents only on start, so today it shows only after a restart. Refusing at admission is offered in the decision packet. |
| 3 | LOW | P3's advice "attest the outcome" leads to the loop again through "attest not applied" on an expired idempotent key. | **Fix F2**: the refusal now says "attest that it applied, or abandon with the acknowledgment"; the operator guide says the same. Not changed in code: an attested not-applied with an expired key goes back to unknown at dispatch. That is safe but not useful, and it is recorded as a limitation. |
| 4 | LOW | The guidance after `effect-key-in-use` is incomplete, and the halt names only one operation. | **Fix F2**: the refusal names the holding operations and gives the steps: abandon one, requeue without the key, carry the other. The halt reason stays as frozen. |
| 5 | INFO | Stale doc comments. | **Fixed.** |
| 6 | INFO | No refusal record for P3; untested: a settled-not-applied sibling, a retry inside the key guarantee. | **Tests added** (F3). The `resolveOutcome` refusals write no refusal record, as before: recorded. |
| 7 | INFO | The install-directory rule accepts `.local/.` and `.local/config`. | **Fix F4**: only `.local/install` or `.local/<name>-install`, and not a symlink. |
