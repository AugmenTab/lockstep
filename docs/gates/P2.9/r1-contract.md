# C-P2.9-R1 — Gate B remediation

- Contract ID: `C-P2.9-R1@v1`
- Status: **DRAFT**, waiting for R-P2.9-2 (three frozen P2.7 cases, §5). Nothing in §2 is
  implemented yet.
- Authority: `.local/plans/phase-02_update2.md`: bounded remediation of the independent review
  (`docs/gates/B/review.md`), items 1–7. Amendments to earlier Contracts' *text* (C-P2.5 E8,
  C-P2.6 X5/X7/X10, C-P2.8 §3) are made here under that authorization. **Frozen tests are changed
  only by R-P2.9-2, after the owner approves it.**
- Writer: the single writing agent (Implementer).

## 1. Objective

Close the review's defects without widening Phase 2:
- an idempotency key's lifetime is enforced;
- intents are fenced to the activation that authorized them;
- ledger reads are consistent snapshots, and partial writes roll back;
- abandonment and human attestation carry their DG-04 meaning;
- real contention is proven deterministically;
- the remaining LOW findings are fixed, and the B1 harness is isolated from the owner's
  installation.

## 2. Decisions

| # | Decision | Review finding |
|---|---|---|
| M1 | **Key lifetime.** The first dispatch time is stored once, from the database clock (`first_dispatched_at`). The idempotency guarantee holds until `first dispatch + lifetime − margin`, with margin = max(30 s, lifetime / 10). It is unverifiable when there is no first dispatch time. A recovery that would re-dispatch an `idempotent` intent whose guarantee no longer holds, or cannot be verified, becomes unknown `dispatch-interrupted: idempotency key may have expired` instead. That halts the order, and nothing is re-dispatched. A pure Kernel function decides this (`Lockstep.Kernel.KeyLifetime`); C-P2.6 `Kernel.Recovery` is unchanged. A `confirmed-not-applied` retry is still allowed: the destination said not applied, so a repeat cannot duplicate. | 1 |
| M2 | **Activation fencing.** Each intent stores the claim generation of the start or resume that authorized it (`activation_generation`). Claim for execution, dispatch and recovery-redispatch require the order to be `active` under that same claim generation. Otherwise the claim and dispatch are refused `activation-superseded` and nothing is written, and recovery treats the order as not active, so the intent becomes unknown, never re-executed. Selection (`runnableIntents`) skips superseded intents. Superseded intents keep their state and evidence, and lookups and human resolutions still apply to them. **Carry-forward** is the only way an earlier intent runs again: `carryIntent` (Human) rebinds a `pending`, lapsed-`claimed` or `confirmed-not-applied` intent of an active order to the current generation. It records a resolution with basis `human-carry`. CLI: `effects carry OPERATION`. This keeps DG-04 requirement 1, under which a retry keeps its operation id. | 2 |
| M3 | **Consistency.** `readLedger` runs under `REPEATABLE READ READ ONLY`. In every Ledger transaction, an integrity failure found after a write aborts and rolls back; only pure refusals commit, with their refusal evidence. | 3, 5 |
| M4 | **Abandonment and attestation.** `abandonIntent` (Human) does three things in one transaction: the C-P2.5 abandon, a resolution with basis `human-abandon` (`abandoned reason="<r>"`), and a halt of the order with `abandoned operation=<uuid>` when its lifecycle accepts one. The reason is validated like evidence (`invalid-record`). Display: an outcome that a human attested shows **`ATTESTED`**. That means its outcome text begins `human-attested: `, or an attested-applied record exists, either one being enough (finding 8). This holds for settled applied, settled not applied and `confirmed-not-applied` alike, before `BLOCKED`. So a human "not applied" is never shown like a destination's `NOT_APPLIED`. Amends C-P2.8 §3 rows 2, 4, 10, 14 and 15. Tests use scripted actions and never claim the human owner performed them. | 4, 8, 9 |
| M5 | **Real overlap.** A new integration regression uses two worker processes, both instances of the integration binary. Worker 1 claims the intent and holds the claim, which stays genuinely active, until the test releases it. While worker 1 holds it, worker 2 runs `executeIntent` on the same intent and is refused `claim-held`. The test then checks that the intent is still claimed by worker 1 at generation 1, which proves the overlap, and releases worker 1, which applies the effect. The PostgreSQL destination then shows exactly one application. B1 gains **AC-B1-18**: while an installed `execute-once` holds a dispatched idempotent effect that is still hanging, a second installed `execute-once` is refused `dispatched-needs-recovery`. The first is then killed and recovered, and the sandbox shows one application. | 6 |
| M6 | **Remaining findings.** Dispatch renews the lease (database `clock_timestamp()` + the executor's lease) and checks it on the same clock (finding 10). `executeOnce` leaves queryable recoverable intents to `reconcileOnce` (11). Halt, wait and abandon reasons are validated: 1–4096 characters, no control characters (13). `scripts/b1` scans `b1.log` too, scans for the bare token, and drops the unused session variable (7). The C-P2.5 intent functions that skip the order checks are documented as test-level API (12, recorded). | 7, 10, 11, 12, 13 |
| M7 | **Isolation.** `scripts/service` accepts `LOCKSTEP_SERVICE_INSTALL_DIR`; `scripts/b1` installs into `.local/b1-install` and never touches `.local/install`. B1 only *creates* its own database on the operator server. The owner's binary, which B1 run 1 overwrote, is restored by rebuilding the Gate A commit `6c2851d` into `.local/install`, with its `VERSION`. B1 run 1 stays as history. | 16 |
| M8 | **Migration 0012** (forward-only): adds `first_dispatched_at` and `activation_generation` to `lockstep_effect_intents` (existing rows: the generation of their order's first claim, which is the only possibility in a schema without carry-forward), and widens the resolution `basis` check with `human-abandon` and `human-carry`. | 1, 2, 4 |

## 3. New tests (frozen before implementation)

- **Unit:** the key-lifetime function (inside and outside the window, at its boundary,
  unverifiable, other classes unaffected). EffectView's new attested rows.
- **Integration, real PostgreSQL:**
  - *Expiring key:* with an expiring-key destination fixture whose keys really expire, a crash
    after the effect, then recovery past the guarantee, gives unknown and no second
    application. A control call shows the fixture would have applied again.
  - *Activation fencing:* halt, requeue and restart; an earlier intent is refused
    `activation-superseded`, is skipped by `executeOnce`, and keeps its evidence; it runs once
    after `carryIntent`.
  - *Consistency:* a ledger read concurrent with decisions never reports an integrity failure.
  - *Rollback:* an injected integrity failure after a write commits nothing.
  - *Abandonment:* abandoning halts the order and records the decision.
  - *Attestation:* attested not-applied shows `ATTESTED`.
  - *Overlap:* the M5 regression, with real worker processes.
  - *Lease renewal* and *reconciliation-first selection.*
- **B1:** AC-B1-18.

## 4. Verification

Before the freeze: baselines against stubs, with the setup exercised on its own, and the static
rules checked. Acceptance:
- `scripts/check --integration`, a fresh clone and a Linux clone;
- B1 (run 2);
- a second independent read-only review of the remediation;
- then the Gate B report and the decision packet.

## 5. Frozen tests that must change

Three C-P2.7 cases encode the behaviour M2 and M4 remove. The exact diff is
`r-p2.9-2-amendment-request.md`; it is not applied without the owner.
