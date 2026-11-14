# DG-08 — recorded owner decision

- Decided by: the owner, 2026-11-14, by instructing implementation of `.local/plans/phase-06_update1.md` (§3, §4, §5).
  Recorded by the Implementer as the owner's decision; the Implementer accepts nothing on its own authority.
- Packet: `docs/gates/DG-08/decision-packet.md` (Option 2 recommended there).

## 1. Decision

**Option 2: an immutable approved Master Plan outline, with bounded just-in-time Contract elaboration.**

### 1.1 Frozen by an approved plan revision (digest-bound)

As stated in update 1 §3:

1. Source PRD and architecture identities (by identity and SHA-256).
2. Project and repository ownership.
3. Stable work identities and the dependency graph (edges and their kind).
4. Required outputs and acceptance criteria.
5. Risk and external-effect classifications.
6. Execution authority, limits and mandatory verification.
7. The exact plan revision and its digest.

### 1.2 What the Planner may and may not do

The Planner may elaborate routine implementation detail inside those constraints. It may not unilaterally: remove or
weaken requirements; change architectural obligations; alter approved dependency semantics; expand external-effect
permissions; bypass frozen tests or review; replace the effective plan revision without authorization.
Consequential changes need a new proposed revision and the owner's approval. The deterministic Supervisor validates
every proposed refinement and keeps prior plan history.

## 2. Reconciliation with the packet (update 1 §3: "report any conflict")

No contradiction was found. Differences, reported rather than silently resolved:

| Packet item | Update 1 | How it is recorded |
|---|---|---|
| §3.2.2 phase/subphase placement of a unit | not named | Kept frozen as part of "stable work identities" (placement is part of the unit's identity in the approved outline). **Owner may say otherwise.** |
| §3.2.6 effective Profile per unit and which edges may be satisfied provisionally | not named separately | Treated as part of "execution authority, limits and mandatory verification" (a Profile binds the mandatory verification; the provisional-edge policy is execution authority, D6-AUTH). Frozen. |
| §3.2.8 owner priorities | not named | Kept frozen in the revision (a priority change is a new revision). This is the stricter reading. **Owner may relax it.** |
| §3.4 amendment triggers, §3.5 reconciliation/invalidation, §3.6 recovery | "consequential changes require a new proposed revision"; "preserves prior plan history" | Adopted as in the packet. |
| §3.7 no separate local Phase signoff in Phase 6 | not decided | **Left OPEN.** Nothing implements a Phase signoff authority; Human Done stays per task. This matches the packet's recommendation by omission, but it is not recorded as decided. |
| §4 frozen-test question | §4 authorizes amendment A-P6.4-1 (choice A) | Applied narrowly; see `docs/gates/P6.4/amendments.md`. |

## 3. Status

DG-08: **DECIDED (Option 2)**, local Phase signoff OPEN. P6.4's Contract may be frozen on this basis.
