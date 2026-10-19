# Gate B — independent read-only review and dispositions

- Reviewer: a separate **read-only** reviewer agent of the same model family as the writer. It
  had no edit, write, build, Docker or network use; it read files and ran read-only git only.
  **This is not a human review.**
- Scope: `git diff 6c2851d..1e59942 -- src app scripts static test package.yaml henforcer.toml
  .hlint.yaml`, against C-P2.1–C-P2.9, DG-03, DG-04 (requirements 1–8) and DG-05.
- Date: 2026-10-19. Result: **no HIGH findings**; 6 MEDIUM, 7 LOW, 3 INFO.
- Dispositions are proposed by the writing agent (Implementer). Nothing has been changed yet.
  Items marked **owner** need the human owner's decision.

## What it found clean

The reviewer found nothing in these areas:
- an effect without a committed claim and dispatch marker;
- a stale-generation write accepted;
- a refused observation dropped;
- a NoAnswer, timeout or exception turned into applied or not applied;
- unparameterised SQL;
- a lock-ordering cycle;
- a secret in product output;
- an `Agent` principal accepted anywhere.

It checked the frozen files by git history, not SHA-256: none changed after its freeze except
the two owner-approved amendments, R-P2.3-1 and R-P2.5-1.

## Findings

| # | Sev. | Finding (summary) | Proposed disposition |
|---|---|---|---|
| 1 | MEDIUM (HIGH with a real class-B adapter) | The class-B key lifetime is declared but never enforced: recovery or a retry can re-dispatch the same operation id after the destination's key has expired, so the destination no longer deduplicates (DG-04 requirement 2). The sandbox keys never expire, so no test can see it. | **Fix** (remediation): record the first dispatch time; a class-B intent past `first dispatch + lifetime − margin` becomes unknown, never re-dispatched. |
| 2 | MEDIUM | Intents of an earlier activation run again after a halt, requeue and restart, beside the new activation's intents for the same effect keys: one logical effect, two operation ids. | **Fix** (remediation): bind each intent to the order's claim generation that authorized it; refuse claim and dispatch under another generation. |
| 3 | MEDIUM | `readLedger` runs at READ COMMITTED, so a decision that commits during the read can show as `LedgerIntegrity` (exit 70, a 500 page), a false tamper signal. No false `PASSED` was found. | **Fix**: `REPEATABLE READ READ ONLY` for the read. |
| 4 | MEDIUM | Abandon neither halts its subject nor writes a record. DG-04 D-4.6 says "abandon the intent and halt its subject"; C-P2.5 E8 implemented it more narrowly. | **Owner.** Proposed: halt the order and write a `human-abandon` resolution row in the same transaction. |
| 5 | LOW (latent) | `transaction` commits whatever the action returns, so an integrity `Left` returned after earlier writes would commit partial state. These branches are unreachable while the Kernel invariants hold. | **Fix**: after any write, an integrity failure throws, so the transaction rolls back. |
| 6 | MEDIUM | AC-B1-15 can pass without a real race: two `docker run` containers usually serialise, and `idle` is accepted. | **Fix together with R-P2.9-1**: use a long-running effect and require proof that the two processes overlapped (a refused claim, or both inside one lease window). R-P2.9-1 needs amending accordingly. |
| 7 | LOW | B1's secret check has gaps: `session` is never set, and `token_leaks` does not scan `b1.log`. | **Fix** in `scripts/b1`. |
| 8 | LOW | `ATTESTED` depends only on the resolution row; with the row missing, a `human-attested:` outcome would show `PASSED`. | **Fix** (defence in depth): either signal is enough for `ATTESTED`. |
| 9 | LOW / INFO | A human "attest not applied" shows `NOT_APPLIED`, like a destination's answer, with only the reason text distinguishing it. | **Owner** (a distinct status would amend C-P2.8 §3). |
| 10 | LOW | The lease is not renewed at dispatch, and the check uses the transaction's start time. | **Fix**: a fresh lease end at dispatch. |
| 11 | LOW | `execute-once` recovers a lease-ended queryable intent (making it unknown) before a lookup could resolve it. This affects liveness, not safety. | **Fix**: recovery leaves queryable intents to reconciliation. |
| 12 | LOW | The C-P2.5 intent functions skip the active-order check; the binary does not call them. | **Recorded**: they are the frozen C-P2.5 API. |
| 13 | LOW | Halt and abandon reasons are not validated: a newline breaks the one-line rendering. | **Fix**: validate like evidence text. |
| 14 | INFO | Authority comes from which command is called, not from an authenticated principal, by design (C-P1.3, C-P2.8 V4). | **Recorded** for Phase 3. |
| 15 | INFO | DG-03 residuals already listed in C-P2.1. | **Recorded.** |
| 16 | INFO | B1's `scripts/service install` replaces the shared `.local/install` binary that the owner's `lockstep-service` also uses, contrary to C-P2.9 Q1's wording. Also, the service restarts in AC-B1-12/16 do not affect the CLI paths they check. | **Recorded**, and corrected in the Gate B report. Your service is stopped; your operator database is untouched (schema 5) and needs a backed-up `db migrate` before your service is restarted on the new binary. |
