# DG-04 — decision request: event, claim, outbox, replay and reconciliation protocol

- Prepared by: the writing agent (Implementer), 2026-10-18. **Nothing here is decided.** The
  human owner decides DG-04. Status: `EVIDENCE-PREPARED`.
- Blocks: P2.5 (durable events, claims, intents, outbox), then P2.6 and P2.7. Basis: the pure
  lifecycles of C-P2.2 (`ed9e160`); the P1.5 no-op dispatcher, whose lease rule was ratified **for
  no-op jobs only** and explicitly does not decide DG-04.
- Sources: Bible §38 ("PostgreSQL … does not itself supply exactly-once side effects … Do not
  replay an irreversible or expensive external operation merely because its response was lost";
  "No heartbeat should imply that a still-running subprocess vanished"); PRD §6.2 (recovery
  contract: atomic state and intents, effects outside the transaction, reconcile from the
  authoritative destination, `RECOVERY_REQUIRED` and a human when unprovable, reject an old
  worker's late observation); PRD §4.1 (separate invalid, forbidden, conflict, human halt,
  recoverable error and **unknown outcome**); FR-EXE-02; DG-04 default ("a concrete crash table
  per effect; no magical exactly-once claim"); handoff §9–§11.
- Phase 2 executes only **scripted, model-free** effects (P2.6). The protocol must still be right
  for the real effect classes of later phases.

## D-4.1 Durable decision: events and intents together

**Recommended:**

- Each authorized Kernel decision commits in **one PostgreSQL transaction**:
  - an expected-revision check on the subject (Ticket, Work Order, Work Unit or Delivery); a
    mismatch is `stale-revision`, nothing is written;
  - the appended domain event(s) (an append-only log, with a per-subject sequence and a
    revision);
  - the new state projection;
  - the effect intents.
- Each intent has a Lockstep-issued **operation id** (UUID, unique), its effect class (D-4.3),
  typed parameters, the authorizing decision, and a uniqueness key (subject, intent kind, basis
  revision). A replayed decision therefore cannot create a second intent.

## D-4.2 Claims, leases and fencing

**Recommended:**

- A worker claims one intent in a transaction. The claim records an owner, a monotonically
  increasing **fencing generation** (per intent) and a lease expiry.
- Every later write for that intent must carry the generation it claimed with, and a write with
  an older generation is refused (`stale-claim`). This covers the dispatch marker, the
  observation and the settlement.
- **An expired lease proves nothing about the effect.** It allows a new claim (a higher
  generation), but what the new owner may do depends on the effect class and on whether a
  dispatch marker exists (D-4.4, D-4.5).

## D-4.3 Effect classes (by what reconciliation can prove)

| Class | Meaning | Phase 2 example (scripted) | Later real example |
|---|---|---|---|
| **A** repeatable | re-executing is harmless; no external trace | no-op step, read-only inspection | `git status`, test discovery |
| **B** idempotent at destination | the destination deduplicates by operation id | scripted adapter honouring an idempotency key | PR create with an idempotency key; compare-and-swap ref update |
| **C** queryable | the destination can be asked whether the operation id was applied | scripted adapter with a lookup | Git commit carrying an operation-id trailer; process tree |
| **D** unqueryable or irreversible | cannot be proved absent or present; expensive | scripted adapter with no lookup | model invocation, email, push without a lookup |

Each effect kind declares exactly one class. Declaring a weaker class than the effect really has
is a Contract defect, not a runtime choice.

## D-4.4 Outcome vocabulary

**Recommended:** an intent is in exactly one of these states:

- `pending` (no claim);
- `claimed`;
- `dispatched`: a durable dispatch marker committed **before** the effect is attempted;
- `confirmed_applied`;
- `confirmed_not_applied`;
- `outcome_unknown`;
- `settled`: the observation was applied by a new Kernel decision;
- `abandoned`: only by a human.

A timeout or a lost response is `outcome_unknown`, never a failure. An error that the
destination itself reports is `confirmed_applied` (with an error result) or
`confirmed_not_applied`, according to what the destination says.

## D-4.5 Crash table (recovery by window and class)

| Window | Durable truth | A | B | C | D |
|---|---|---|---|---|---|
| W1 crash before the decision commits | nothing | re-decide | re-decide | re-decide | re-decide |
| W2 after commit, before a claim | `pending` | claim | claim | claim | claim |
| W3 after the claim, before the dispatch marker | `claimed`, no marker: **not dispatched** | reclaim and dispatch | reclaim and dispatch | reclaim and dispatch | reclaim and dispatch |
| W4/W5 marker committed; the effect may or may not have happened | `dispatched` | re-execute | re-dispatch with the **same** operation id | query by operation id: present → `confirmed_applied`; absent → `confirmed_not_applied`; the query fails → `outcome_unknown` | **`outcome_unknown`**; halt for a human |
| W6 observation stored, not yet settled | `confirmed_*` | settle from the stored observation (idempotent) | same | same | same |
| W7 a late or duplicate observation after settlement, or from an old generation | — | refused (`stale-claim` / `already-settled`) and **recorded** as late-observation evidence, never silently dropped | same | same | same |

A `confirmed_not_applied` intent may be re-dispatched only within its finite retry budget, under
a new generation. A class-D intent is **never** re-dispatched automatically.

## D-4.6 Human resolution of `outcome_unknown`

**Recommended:** a durable human decision bound to the exact intent and generation. The human
chooses one of:

- *mark applied*, with optional evidence;
- *mark not applied*, which permits re-dispatch within the budget;
- *abandon* the intent and halt its subject.

A duplicate answer cannot relaunch the effect (FR-EXE-07). An agent cannot answer.

## D-4.7 Retry budgets

**Recommended:** each intent kind has a finite budget (default 3 for A–C, 0 automatic for D).
Exhausting it halts the subject with `retries-exhausted`. Budgets are part of the effect kind's
declaration, not a generalized retry loop (handoff §10).

## D-4.8 The Phase 1 no-op dispatcher

**Recommended:** keep it unchanged in Phase 2. Its jobs and the P1.5 lease rule stay as they are;
the new protocol uses its own tables. Moving no-op jobs onto the new protocol (as class A) is a
later, separately recorded change.

## D-4.9 Where the protocol lives

**Recommended:**

- The decision, event append, intent creation, claim, fencing and settlement rules are pure
  Kernel functions plus Persistence transactions.
- Dispatch and effect-specific reconciliation (query by operation id) live in typed interpreters
  under `Lockstep.Effects`.
- There is no generic retry wrapper.
- In-memory coordination may help but is never the source of truth (PRD §6.2).

## Adversarial cases the Contracts would freeze (P2.5–P2.7, under the recommendations)

1. The state change and its intent commit together or not at all: a fault injected between them
   leaves neither.
2. A replayed decision creates no second intent (uniqueness key).
3. Two workers claiming one intent: exactly one generation wins; the loser's writes are refused.
4. A crash in W3 leads to a safe reclaim; a crash in W4/W5 follows the class rules above; a class-D
   intent ends `outcome_unknown` and is never re-dispatched by restart or by lease expiry.
5. Class C: the query proves present → applied; proves absent → not applied; the query fails →
   unknown. Nothing is fabricated.
6. A late observation from generation *n* after generation *n+1* was claimed is refused and
   recorded.
7. A timeout is `outcome_unknown`, never `confirmed_not_applied` and never success.
8. A human resolution applies once; a duplicate does nothing.
9. Real cross-process contention (two `lockstep` processes, real PostgreSQL) gives no duplicate
   execution of a class B/C/D effect.

## Human decision (to be filled in by the owner)

| Field | Value |
|---|---|
| D-4.1 events + intents in one transaction | |
| D-4.2 claims, leases, fencing generations | |
| D-4.3 effect classes A–D | |
| D-4.4 outcome vocabulary | |
| D-4.5 crash table | |
| D-4.6 human resolution of unknown | |
| D-4.7 retry budgets (default 3 / D: 0) | |
| D-4.8 no-op dispatcher unchanged | |
| D-4.9 placement | |
| Decided by / at | |

## Human decision (2026-10-18)

Recorded by the writing agent (Implementer) at the owner's instruction
(`.local/plans/phase-02_update1.md`). The owner's words, verbatim:

> ### DG-04 — APPROVED WITH SAFETY CLARIFICATIONS
>
> Approve D-4.1 through D-4.9 as the foundation, subject to these binding requirements:
>
> 1. **Stable intent identity:** Distinct legitimate effects authorized at the same subject revision must remain distinct. Use a stable effect identity within the authorizing decision. Retries must retain the original operation ID and parameters.
>
> 2. **Class B:** Destination idempotency must be real and documented, including key lifetime and parameter consistency. A repeated request may occur, but must not create an unintended duplicate effect.
>
> 3. **Class C:** A negative destination lookup counts as `confirmed_not_applied` only when the destination can authoritatively establish non-application, including that an earlier in-flight attempt cannot subsequently apply. Otherwise the outcome remains UNKNOWN and automatic re-execution is forbidden.
>
> 4. **Fencing:** Database fencing rejects stale writes but does not cancel external work. Preserve late observations as reconciliation evidence. Do not silently ignore evidence that an old worker may have completed an external effect.
>
> 5. **Class D:** Never automatically re-dispatch after an uncertain attempt. Any human-authorized retry following an unknown outcome must be explicit, auditable, and acknowledge the risk of duplication.
>
> 6. **Human resolution:** Distinguish human-attested outcomes from independently verified observations in durable evidence. Never present an unverified human assertion as destination-confirmed proof.
>
> 7. **Retry semantics:** Keep finite, effect-specific budgets. Do not introduce generic retries that bypass class-specific safety rules.
>
> 8. **Testing:** Prove no unintended duplicate external effects, not an impossible blanket guarantee of exactly-once invocation. Include delayed workers, expired leases, late external completion, ambiguous negative lookups, duplicate requests and cross-process contention.
>
> The Phase 1 no-op dispatcher remains unchanged. Its provisional lease behavior does not authorize general external-effect replay.

| Field | Value |
|---|---|
| D-4.1 events + intents in one transaction | ACCEPTED; requirement 1: the uniqueness key includes a stable effect identity within the decision, so distinct effects at one revision stay distinct |
| D-4.2 claims, leases, fencing generations | ACCEPTED; requirement 4: fencing refuses stale writes but cancels nothing; late observations are kept as evidence |
| D-4.3 effect classes A–D | ACCEPTED; requirements 2 (B: documented key lifetime and parameter consistency) and 3 (C: negative lookup authoritative only if a late in-flight application is excluded) |
| D-4.4 outcome vocabulary | ACCEPTED |
| D-4.5 crash table | ACCEPTED, amended by requirements 3 and 5 |
| D-4.6 human resolution of unknown | ACCEPTED; requirements 5 and 6: human-attested outcomes are marked as such; a human retry after unknown acknowledges the duplication risk |
| D-4.7 retry budgets (default 3 / D: 0) | ACCEPTED; requirement 7 |
| D-4.8 no-op dispatcher unchanged | ACCEPTED |
| D-4.9 placement | ACCEPTED |
| Decided by / at | the human owner, 2026-10-18 |

Status: **ACCEPTED** (with binding safety requirements 1–8). C-P2.5–C-P2.7 incorporate them.
