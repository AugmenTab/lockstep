# DG-05 — decision request: Profile policy, precedence, exceptions and scheduling order

- Prepared by: the writing agent (Implementer), 2026-10-18. **Nothing here is decided.** The
  human owner decides DG-05 (Decision Register; PRD §5.1 says the human must accept the
  precedence and urgent-rework rules before the Contract is frozen). Status: `EVIDENCE-PREPARED`.
- Blocks: P2.3 (Profile policy) and P2.4 (scheduler). Basis: P2.1 and P2.2
  `VERIFIED — awaiting human acceptance` (`2eb97c5`, `ed9e160`).
- Sources: Bible §3.5 ("may strengthen or specialize, but never silently weaken"; "a missing
  mandatory artifact, unresolved policy conflict, or unapproved exception blocks progression"),
  §31.2 (universal invariants), §32 (resolution sequence; "do not guess which authority wins";
  "persist … before creating or admitting the Work Unit"; mid-flight change); PRD §5.1 (proposed
  ordering), §5.2 (gate semantics; "avoid a general user-scriptable policy language at Gate B"),
  FR-WRK-03/05/09/10; handoff §7–§8.
- Scope reminder: Phase 2 builds the common policy foundation, not the Bug Fix, Greenfield or
  Brownfield templates (Phase 3+). The Kernel already freezes the Work Unit gate mechanism
  (`frozenGates`, `gates-pending`; C-P2.2).

## Part A — Profiles (P2.3)

### D-5.1 Schema

**Recommended (D-5.1a):** a Profile is a versioned, declarative value with an id, a version, a
SHA-256 digest of its canonical rendering, and a list of gates. Each gate has an id; an artifact
kind; an applicability predicate drawn from a fixed vocabulary (work-order kind, classification
tag, changed-path class); a verifier kind; an approval authority; whether a typed exception path
exists; and the disposition on missing or ambiguous evidence, which is always *block*. There is
no expression language or scripting (PRD §5.2). Alternative D-5.1b: free-form gate lists without
a fixed predicate vocabulary (more flexible, but harder to prove "never weaker").

### D-5.2 Universal invariants

**Recommended:** the Bible §31.2 list is a fixed set in the Kernel that every effective Profile
contains implicitly:

- one mutating Implementer per repository;
- scope and authorization checks;
- durable attempts;
- protected frozen tests where behaviour changes;
- deterministic verification;
- independent read-only review;
- bounded retries;
- legitimate Git commits;
- human completion authority.

A Profile that omits, relaxes or declares an exception for any of them is **refused when
resolved** (`weakens-universal-invariant`). Only "protected frozen tests where behaviour changes"
has a typed path, the non-behavioural classification (D-5.4), because the invariant applies only
to behaviour-changing work.

### D-5.3 Precedence

**Recommended (D-5.3a):** resolve in this order:

1. the installation baseline;
2. the repository default (from the Engineer's configuration, D-3.5a);
3. a work-class specialization that the repository default **declares** for this Work Order
   kind or classification;
4. explicit, human-approved stricter overrides.

Each later layer may only add gates or strengthen a gate (stricter approval authority, an
exception path removed). It may never remove one. Two layers giving one gate incompatible
settings is a conflict, refused (`profile-conflict`): no layer silently wins.
Alternative D-5.3b: later layers may replace earlier ones wholesale (simpler, but weakening
becomes invisible).

### D-5.4 Exceptions

**Recommended:** an exception is a durable human receipt with:

- the exact scope: one Work Order id, or one Work Unit id, plus one gate id;
- a rationale;
- the approver;
- the date;
- the Profile digest it was granted against.

It is valid only if that gate declares an exception path, never for a universal invariant, and
only for the bound work (it does not carry over to new work). A Planner or agent recommendation
is never an exception.
Question for you: should exceptions also expire at a time? Recommended **no**: they are scoped to
one piece of bound work, and that already ends.

### D-5.5 Binding and mid-flight change

**Recommended:**

- The effective Profile is bound **before** effectful admission: the Profile id, version and
  digest; the source layers and their digests; the overrides; the exception receipts; and the
  approval basis. It is bound to the Work Order at admission and copied, unchanged, into the
  Work Unit's frozen Contract.
- A later Profile change never rewrites a bound Work Order or a frozen Work Unit.
- For admitted work that is not yet executing, a changed source Profile makes the Work Order
  ineligible (`profile-changed`) until a human either re-binds it to the new version or confirms
  the old binding. Bible §32 calls this "an explicit reconciliation decision".

### D-5.6 Trusted origin

**Recommended:** the work origin (a human-created Ticket in Phase 2) may select the work class,
which feeds the specialization in D-5.3, but can never lower requirements. Text from an untrusted
source (ticket body, model output) cannot select a class; the class is a typed field set by a
human or by an authorized adapter mapping.

## Part B — Scheduling (P2.4)

### D-5.7 Eligibility filters

**Recommended (PRD §5.1).** A Work Order is eligible only if all of these hold:

- its dependencies are completed;
- its required gates and authorizations are satisfied for the bound Profile;
- its repository is owned and has no other active (claimed, active or waiting) Work Order, since
  one Engineer means one active order per repository;
- every needed resource is known to be available;
- its source revision is current (not `stale`).

An ineligible order gets a typed reason, recorded as refusal evidence.

### D-5.8 Ordering among eligible orders

**Recommended (PRD §5.1):**

1. the highest human-approved priority;
2. then the oldest eligible admission;
3. then the smallest `WorkOrderId` as a stable tie-breaker.

Priority is an integer set only by a human, or by a versioned, human-approved adapter mapping
(later). An imported timestamp or a model suggestion cannot change it. A blocked high-priority
order is never selected over an eligible lower one; it is reported with its blocking reason.

### D-5.9 Urgent rework

PRD §5.1 allows a "separately approved urgency class" for review obligations.

- **Recommended (D-5.9a):** no urgency class in Phase 2. Rework is ordinary priority (there is no
  PR flow before Phase 6).
- Alternative D-5.9b: an `urgent` class ranked above priority, still obeying safe boundaries.

### D-5.10 Unknown resources

**Recommended:** an unknown quota or reservation is **not available**. The order is ineligible
with reason `resource-unknown`, and no number is invented. In Phase 2 the only resource is the
repository reservation; provider quotas come in P5.3.

### D-5.11 Safe boundaries and preemption

**Recommended:** a priority change is observed at the next scheduling decision. An active Work
Order is never preempted in Phase 2. Emergency interruption is a separate, explicit human halt
(the C-P2.2 `WoHalt`), not a scheduling effect.

## Adversarial cases the Contracts would freeze (under the recommendations)

1. A Profile that drops a universal invariant, or declares an exception path for it, is refused.
2. A specialization that removes a gate, or makes it less strict, is refused.
3. Two overrides that disagree on one gate are refused as a conflict, whatever their order.
4. An exception without an exception path, for a universal invariant, scoped to another Work
   Order, or granted against another Profile digest, is refused.
5. A Profile changed after binding leaves the frozen Work Unit unaffected; the not-yet-executing
   order becomes `profile-changed`.
6. Effective Profile provenance is complete: the layers, digests, overrides, receipts and approver
   reproduce the digest.
7. A blocked highest-priority order is excluded; the eligible lower-priority order is selected.
8. Ties are broken by admission time, then `WorkOrderId`; selection is independent of input order.
9. An unknown resource is `resource-unknown`, never assumed available.
10. A second active order for the same repository is ineligible.
11. A stale source revision is ineligible.
12. Replaying the same authoritative inputs gives the same selection and refusals.

## Human decision (to be filled in by the owner)

| Field | Value |
|---|---|
| D-5.1 schema | |
| D-5.2 universal invariants | |
| D-5.3 precedence | |
| D-5.4 exceptions (and expiry?) | |
| D-5.5 binding / mid-flight change | |
| D-5.6 trusted origin | |
| D-5.7 eligibility filters | |
| D-5.8 ordering | |
| D-5.9 urgent rework | |
| D-5.10 unknown resources | |
| D-5.11 safe boundaries / preemption | |
| Decided by / at | |
