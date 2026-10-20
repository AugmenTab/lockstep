# C-P2.9-R1 — Gate B remediation

- Contract ID: `C-P2.9-R1@v1`
- Status: **FROZEN** (2026-10-19; §4.1). R-P2.9-2 was **approved** by the owner (Option A, `carryIntent`), with six
  carry requirements, which §2.1 incorporates.
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
| M5 | **Real overlap.** A new integration regression uses two worker processes, both instances of the integration binary. Worker 1 claims the intent and holds the claim, which stays genuinely active, until the test releases it. While worker 1 holds it, worker 2 runs `executeIntent` on the same intent and is refused `claim-held`. The test then checks that the intent is still claimed by worker 1 at generation 1, which proves the overlap, and releases worker 1, which applies the effect. The PostgreSQL destination then shows exactly one application. B1 gains **AC-B1-18**: while an installed `execute-once` is still running and holds a dispatched idempotent effect, a second installed `execute-once` executes nothing. The installed CLI cannot target one intent, and its selection never offers an in-flight one, so the second is `idle`; the refusal proof is the integration regression above. The first is then killed and recovered, and the sandbox shows one application. B1 also gains AC-B1-19 (M7). | 6 |
| M6 | **Remaining findings.** Dispatch renews the lease (database `clock_timestamp()` + the executor's lease) and checks it on the same clock (finding 10). `executeOnce` leaves queryable recoverable intents to `reconcileOnce` (11). Halt, wait and abandon reasons are validated: 1–4096 characters, no control characters (13). `scripts/b1` scans `b1.log` too, scans for the bare token, and drops the unused session variable (7). The C-P2.5 intent functions that skip the order checks are documented as test-level API (12, recorded). | 7, 10, 11, 12, 13 |
| M7 | **Isolation.** `scripts/service` accepts `LOCKSTEP_SERVICE_INSTALL_DIR`; `scripts/b1` installs into `.local/b1-install` and never touches `.local/install`. B1 only *creates* its own database on the operator server. The owner's binary, which B1 run 1 overwrote, is restored by rebuilding the Gate A commit `6c2851d` into `.local/install`, with its `VERSION`. B1 run 1 stays as history. | 16 |
| M8 | **Migration 0012** (forward-only): adds `first_dispatched_at` and `activation_generation` to `lockstep_effect_intents` (existing rows: the generation of their order's first claim, which is the only possibility in a schema without carry-forward), and widens the resolution `basis` check with `human-abandon` and `human-carry`. | 1, 2, 4 |

### 2.1 Carry-forward (the owner's R-P2.9-2 requirements)

`carryIntent` is `carryIntentAs Human`. `carryIntentAs principal op` runs one transaction that
locks the Work Order, then the intent, and asks the pure `Lockstep.Kernel.Activation.carryDecision`.

Check order (code):
1. an `Agent` (`agent-assertion`);
2. anyone but a `Human` (`not-authorized`): no Implementer, Supervisor or agent can carry;
3. the order not `active` (`subject-not-active`);
4. the intent already bound to the current activation (`carry-not-needed`; this is also how a
   duplicate carry is refused);
5. settled or abandoned (`already-settled`);
6. `outcome-unknown` (`outcome-unknown`: an unknown effect is carried only after a human resolution;
   the retry resolution already requires the duplication risk to be acknowledged);
7. `dispatched` (`dispatched-needs-recovery`);
8. `claimed` with an active lease (`claim-held`);
9. `confirmed-applied` (`not-carryable`);
10. `confirmed-not-applied` with no retry left (`retries-exhausted`);
11. an `idempotent` intent that was dispatched before, is `pending` after a human retry, and whose
    key guarantee (M1) no longer holds (`idempotency-key-expired`).

The Ledger also checks that the claiming Engineer still owns the order's repository
(`repository-not-owned`) and that the intent belongs to that order. A refusal writes nothing.

An accepted carry changes only the intent's activation generation. The operation id,
parameters, budget, dispatch count, fencing generation, observations, recoveries and earlier
resolutions are untouched, so no second logical intent exists. It records a resolution with
basis `human-carry` and decision `carried principal=human from-generation=S to-generation=T`.

A late worker of the earlier activation can neither dispatch (`activation-superseded`) nor make
the intent runnable again: a late not-applied observation is recorded, and the intent stays
fenced.

### 2.2 API

```haskell
-- Lockstep.Kernel.KeyLifetime
keyMarginSeconds :: Integer -> Integer                     -- max 30 (lifetime `div` 10)
idempotencyHolds :: Maybe UTCTime -> UTCTime -> Intent -> Bool   -- first dispatch, now; True unless idempotent
-- Lockstep.Kernel.Activation
data CarryInput = CarryInput { carryNow :: UTCTime, carrySource :: Int, carryTarget :: Maybe Int, carryKeyHolds :: Bool }
carryDecision :: Intent -> Command CarryInput -> Either CarryRefusal ()
data CarryRefusal = CarryAgentAssertion | CarryNotAuthorized Principal | CarrySubjectNotActive | CarryNotNeeded
  | CarryAlreadySettled | CarryOutcomeUnknown | CarryInFlight | CarryClaimHeld | CarryNotCarryable
  | CarryRetriesExhausted | CarryKeyExpired
carryRefusalCode :: CarryRefusal -> Text
-- Lockstep.Application.Ledger (additions)
carryIntent :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Intent)
carryIntentAs :: DatabaseRuntime -> Principal -> OperationId -> IO (Either LedgerFailure Intent)
intentActivation :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Int)
probeIntegrityRollback :: DatabaseRuntime -> IO (Either LedgerFailure ())   -- test seam: writes a refusal row, then fails integrity
```

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

## 4.1 Freeze record

Frozen 2026-10-19 by the writing agent (manual).

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RemediationTest.hs` | `ed16cbf34d6be27dadab143f416dff1f3ed5115497ba1404a1fbb5f2dd18f271` |
| `test/integration/Lockstep/RemediationTest.hs` | `4e3918ac06e2ba055e048b93fa852828522ace07ad52496ae68ae50694cdd477` |
| `test/integration/Lockstep/ReconciliationTest.hs` (R-P2.9-2 applied) | `58701dc0225ae812a14d6d86588ca465071cd55f5b2511bc4dd93b70007d0a99` |
| `test/unit/Main.hs` (runner, +2 lines) | `ecf54fc2b239bce46959bdd3139576273a8d4ba277cca9d793a544bcc61afcd4` |
| `test/integration/Main.hs` (runner, +2 lines) | `491953f2b3c9918d16d31170a7a57381ceaca62465ab19a899a3422ff8884d40` |

Pre-freeze verification, against type-only stubs. The stubs: `Kernel.KeyLifetime` (margin 0,
always holds), `Kernel.Activation` (always `carry-not-needed`), refusing Ledger additions, no
migration 0012.
- Build, format and lint are clean, after four hlint hints.
- **Unit** (`r1-evidence/prefreeze-unit-baseline.log`): 14 of 656 fail, all new. The 640 earlier
  tests pass. Two new cases pass, because they assert behaviour that exists already: "other
  classes are unaffected" and "a destination's not-applied answer stays NOT_APPLIED".
- **Integration** (`r1-evidence/prefreeze-integration-baseline.log`): 12 new failures, and the
  earlier tests pass apart from the three R-P2.9-2 cases, which now fail as intended. Each
  failure is at a missing piece: the column, the carry, the abandon halt, the lease renewal,
  the rollback probe, the attested status.

  Four new cases pass against the stubs:
  - The setup, which runs the fixture, the restart helper, the destination tables and a real
    child worker.
  - "Inside the guarantee", which is existing behaviour.
  - **The overlap regression.** The claim fencing it proves already exists (C-P2.5/C-P2.6). It is
    the owner's required evidence that the second worker is refused while the first claim is
    genuinely active.
  - **The concurrent-read case.** It is a stress regression that did not hit the
    READ COMMITTED race in this run. It cannot prove the fix on its own; the fix (M3) is
    verified by reading. This is recorded as a limitation.
- Static rules: the new Kernel modules' identifiers, strings and comments were checked against
  the purity scan; no forbidden facility or provider name appears.

## 4.2 Addendum after the second review (N1–N8; `docs/gates/B/review-remediation.md`)

Within the owner's carry requirements 2–4 and DG-04 requirement 2:

- **N1.** A dispatch of an `idempotent` intent with `dispatches ≥ 1` requires its key guarantee
  (M1). Otherwise the intent becomes unknown `dispatch-interrupted: idempotency key may have
  expired`, the order halts, and the dispatch is refused `idempotency-key-expired`; nothing is
  sent. This is conservative: it also applies after a destination's own not-applied answer.
  The carry's key check (§2.1 item 11) applies to every carryable state.
- **N2.** `carry-conflict` when the target activation already has an intent with the same
  effect key that is not abandoned.
- **N3.** `carryIntentChecked runtime principal op expected acknowledged`. Its `expected` is
  `Just (from, to)` activations, and a mismatch is `stale-carry`. `carryIntentAs p` is
  `carryIntentChecked p Nothing False`. CLI: `effects carry OP --from-activation S
  --to-activation T [--acknowledge-duplication-risk]`.
- **N4.** A `confirmed-not-applied` intent whose outcome is human-attested is carried only with
  the acknowledgment (`duplication-risk-not-acknowledged`).
- **N5.** In `concludeIntent` and `applyLookup`, a settle refused after writing is an
  integrity failure, so it rolls back.
- **N6.** Recovery of a superseded intent: reason `dispatch-interrupted: activation superseded`;
  the current activation is not halted.
- **N7.** The C-P2.5 unchecked intent functions are documented as test-level API.
- **N8.** The abandonment halt is the Human's event.

New tests: `test/integration/Lockstep/RemediationReviewTest.hs` and
`test/unit/Lockstep/Kernel/RemediationReviewTest.hs`, frozen before their implementation
(§4.3). The frozen files of §4.1 are unchanged.

## 4.3 Freeze record for the addendum

**A withdrawn first record (disclosed).** I recorded the digests below before N1–N8 were
implemented. I recorded them without compiling the files, which goes against my practice of
running a test before freezing it. The first build then refused the integration file: an
unused record field `opC` failed `-Werror=unused-top-binds`. No test had run against that
record. I withdrew it and made the one change shown. No assertion changed. Owner, you may
reject this re-freeze.

```diff
   { opA :: OperationId
   , opB :: OperationId
-  , opC :: OperationId
   }
-    [a, b, c'] -> pure (wo, Ops a b c')
+    [a, b, _] -> pure (wo, Ops a b)
```

| File | Withdrawn SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RemediationReviewTest.hs` | `c041482e10e49fb336ffd3c116522e878fafd182cad0f159a37a1c6a60563230` |
| `test/integration/Lockstep/RemediationReviewTest.hs` | `87eedee0945c061a868c2fa36cf1fe7febfa7e70335ee57ba304675817df50ff` |

The re-freeze follows the first full run (§4.4).

## 4.4 First run and re-freeze

The first full run with the fixes in place was `scripts/check --integration` on `d094190` plus
the working tree. All six steps passed: 672/672 unit and 170/170 integration, with
backup/restore. Log: `r1-evidence/addendum-first-run.log`.

The new files cannot compile against the code before N1–N8. They need `carryIntentChecked`,
`CarryRequest`, `carryChecked` and the four-field `EffectsCarry`, so their failing-first state
is "does not build". The files of §4.1 are byte-identical to their frozen digests.

| File | Frozen SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/RemediationReviewTest.hs` | `c041482e10e49fb336ffd3c116522e878fafd182cad0f159a37a1c6a60563230` (unchanged) |
| `test/integration/Lockstep/RemediationReviewTest.hs` | `655bd8865c9a38eac5962f058edfce07ed0e2506b0e3f7b596b19681bd340354` |

## 5. Frozen tests that must change

Three C-P2.7 cases encode the behaviour M2 and M4 remove. The exact diff is
`r-p2.9-2-amendment-request.md`; it is not applied without the owner.
