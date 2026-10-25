# Lockstep v2 — Design Decision Register

- Register ID: LS-V2-DEC-REG
- Revision: 0.1 — DRAFT (P0.1), initialized 2026-10-16
- Sources: PRD v0.2 §11 and §11.1; Plan v0.2 §2.3; Bible v2.1 §40
- Owner of every decision: **the human owner (operator)**. Agents may prepare
  evidence and recommendations; they may not resolve a gate (Bible §40, PRD §11).

## Status vocabulary

- `OPEN` — no recommendation prepared yet.
- `EVIDENCE-PREPARED` — evidence and recommendation drafted; awaiting human.
- `PROPOSED` — a specific choice is on the table for human acceptance.
- `ACCEPTED` — the human accepted it; record carries approver, date and revision.
- `REJECTED` / `SUPERSEDED`.

A Work Unit implementing a gate-dependent subsystem may not freeze a Contract
against a gate that is not `ACCEPTED` (PRD §11.1).

## Decision record protocol (PRD §11.1)

Each accepted gate gets a record with: question, alternatives, choice, affected
FR/NFR, risks, evidence, approver, revision, effective date. Records start
`PROPOSED` and become `ACCEPTED` only on an explicit human act. Proposed
storage: one ADR per gate under the chosen `docs/adr/` (DG-01b decides the repo).

## Register

| Gate | Decision | Owner | Prerequisites | Blocks | Must settle by | Status (2026-10-16) |
|---|---|---|---|---|---|---|
| DG-01a | Launchpad revision, reuse and license/redistribution rights | Human owner | P0.1; Launchpad source available | All committed v2 code | P0.2 | **ACCEPTED** 2026-10-16. See `docs/adr/ADR-0001-launchpad-adoption.md` (C1 BSD-3, C2 private/undecided, C3 remove hyperscript+pandoc; C4 checks at P1.1) |
| DG-01b | v2 repository / branch / history strategy | Human owner | DG-01a | All committed v2 code; artifact placement | P0.3 | **ACCEPTED** 2026-10-16: orphan `v2` branch, one directory, tag `python-v0.1-final`. See `docs/governance/REPOSITORY_STRATEGY.md` |
| DG-02 | DB boot / backup / migration / deployment packaging | Human owner | P1.1 | Persistent app service | P1.2 | **ACCEPTED** 2026-10-17 as proposed. See `docs/adr/ADR-0002-database-operations.md` (PG 17 container; explicit ordered forward-only migrations via `lockstep db migrate`; typed readiness; backups before migrate) |
| DG-03 | Stable ownership key for repo aliases/worktrees/remotes | Human owner | P1.7 | Engineer registration, scheduler claims | P2.1 | **ACCEPTED** 2026-10-18 by the owner: D-3.1a, D-3.2a amended, D-3.3d (new), D-3.4, D-3.5a, D-3.6, D-3.7. See `docs/gates/P2.1/dg-03-decision-request.md` (Human decision) |
| DG-04 | Event, claim, outbox, replay and reconciliation protocol | Human owner | P1.7, P2.2 | Provider/Git execution, safe recovery | P2.5 | **ACCEPTED** 2026-10-18 by the owner with binding safety requirements 1–8 (stable effect identity, real class-B idempotency, authoritative class-C negatives, fencing keeps late evidence, no automatic class-D retry, human attestation distinguished, finite effect-specific budgets, duplicate-effect testing). See `docs/gates/P2.5/dg-04-decision-request.md` (Human decision) |
| DG-05 | Profile schema, precedence, exceptions, scheduling order | Human owner | P2.2 | Effective Profile binding/admission | P2.3–P2.4 | **ACCEPTED** 2026-10-18 by the owner: D-5.1a–D-5.11 as recommended, with clarifications 1–4 (execution prerequisites vs later gates; unprovable strengthening refused; queued ≠ reserved; non-behavioural classification cannot evade mandatory tests). See `docs/gates/P2.3/dg-05-decision-request.md` (Human decision) |
| DG-06 | Test-candidate baseline/RED policy; source-grounded acceptance | Human owner | P3.3–P3.6 | Frozen-test implementation | P3.7 | OPEN — Python regression lessons feed it (P0.3) |
| DG-07 | Semantic challenger independence, budget, disposition, escalation | Human owner | P3.4–P3.5 | Freeze and acceptance in Bug Profile | P3.6 | OPEN |
| DG-08 | Plan import/creation freeze and local Phase signoff | Human owner | P3.5, P4.3 | Plan-driven engine parity | P4.4 | OPEN |
| DG-09 | Git branch/PR granularity, protected merge, status mapping | Human owner | P5.5 | External push / PR | P6.1 | OPEN — PRD §8 proposes PR-per-Ticket first |
| DG-10 | Shortcut field ownership, priority, blocker, Done mapping | Human owner | P6.9, P4.1 | External tracker mutation | P7.1 | OPEN |
| DG-11 | Skill sharing trust/signature, evaluation thresholds, IP | Human owner | P8.2 | Share/export/install | P8.3 | OPEN |
| DG-12 | Red Team target scope, isolation, finding sensitivity | Human owner | P5.5, P4.1 | Active security probes | P9.1 | OPEN |
| DG-13 | Mercury adoption (optional) | Human owner | P2.2 | **Nothing** on default critical path | Optional after P2.2 | OPEN — default is Haskell only |

DG-01 is split into DG-01a (source rights) and DG-01b (repository placement)
because PRD §11 bundles them but the plan settles them in different sub-phases
(P0.2 vs P0.3). This is a bookkeeping split, not a new gate; both halves must be
`ACCEPTED` for DG-01 to be closed.

## Decisions blocking immediate execution

The next dependency-ready implementation item is P1.1. It is blocked by:

1. ~~Human acceptance of Bible v2.1, PRD v0.2, Plan v0.2~~ adopted at Gate P0, 2026-10-16.
2. ~~DG-01a~~ ACCEPTED 2026-10-16.
3. ~~DG-01b~~ ACCEPTED 2026-10-16.
4. ~~Phase 0 gate acceptance~~ ACCEPTED 2026-10-16.
5. ~~Explicit human authorization to begin Phase 1~~ given by the Phase 1 handoff (`.local/plans/phase-01.md`).

Phase 1 license exception: ADR-0003 (LGPL-3.0 `iso3166-country-codes` via Brigid) ACCEPTED 2026-10-17 while v2 is private; must be revisited before any distribution, alongside GMP.

Phase 1 owner decisions, 2026-10-17 (recorded by the writing agent at the owner's instruction):

- P1.1 and P1.2 **ACCEPTED** at `b3a37233e2077de6a196112a2ef46780b71a30bb`; recovery halt lifted (`docs/gates/P1.2/r1-acceptance-packet.md`).
- P1.3 design amendments (`docs/gates/P1.3/decision-request.md`): **D-1a** (present `Host` must be exact; missing `Host` tolerated only on public GET/HEAD; port-80 default forms), **D-2d** (`Referrer-Policy: origin` on the sign-in confirm page; strict exact `Origin` on every mutating request, no `null` exception), **D-3a** (sign-in redirects to `/operator`).

Phase 1 owner decisions, 2026-10-18 (`docs/gates/P1.5/decision-request.md`, "Human decisions"):

- **R-P1.5-1 APPROVED** (conditional on the diff touching only the `healthy` and `jobState` helpers; verified and applied byte for byte, re-frozen in C-P1.5 §9.1).
- Queue-form placement at `/operator/jobs/new` **RATIFIED** (C-P1.5 §9 A1).
- Dispatcher lease `step_millis + 5000` ms **RATIFIED for the model-free no-op dispatcher only**; it does not approve external-effect replay or pre-empt DG-04 (C-P1.5 §9 A2).
- Test-helper connection-pool churn recorded as a known issue; no refactor of accepted P1.2 tests unless required for correctness (C-P1.5 §9.2).

Gate A, 2026-10-18 (`docs/gates/A/r2/browser-forms-regression.md`):

- The owner's human demonstration against report r1 **failed** at step 4 (browser forms refused: `Origin: null` from `no-referrer` pages).
- **Planner decision: Option A.** `Referrer-Policy: origin` on operator pages containing forms; strict exact-Origin guard kept; no `Origin: null` exception; remediation C-P1.7-R1 with real-browser tests.
- **R-P1.3-1 APPROVED** by the owner (one-line frozen-test amendment; re-frozen in C-P1.3 §9.1).

Gate A owner decisions, 2026-10-18 (`docs/gates/A/r2/decision-packet.md`; recorded by the writing agent at the owner's instruction):

- **Gate A ACCEPTED** on report r2, sha256 `33c8d26a0b7a01696fc1e2b4c3f2541fd7062a2d18f60616cc0da895520feaef`, tested commit `6c2851d`. Report r1 (`efee1118…`) is superseded and kept.
- **P1.3–P1.7 ACCEPTED**, including C-P1.7-R1, at their documented tested commits and the Gate A r2 qualification evidence.
- **Session-cookie limitation: option (a) ACCEPTED for Phase 1 only.** Dedicated loopback-host isolation must be addressed before consequential agent execution. This is not an authorization for remote access.
- **Human demonstration (AC-A1-18@v2) PASSED** by the owner's disposition (step 5b confirmed; step 5a agent-run at the owner's request). Findings carried forward: the refusal page reads like success; sign-in usability; restart not shown mid-job.
- The owner's instruction: do not proceed to Phase 2. Phase 2 has not started.

Phase 2 authorization, 2026-10-18 (`.local/plans/phase-02.md`, the owner's Phase 2 handoff): the handoff restates the Gate A decisions above (same report, digest and tested commit, verified again: `33c8d26a…`) and **authorizes Phase 2** (P2.1–P2.9 and a bounded `lockstep open` increment), superseding the earlier "do not proceed to Phase 2". It authorizes no live model inference, provider action, push, PR or remote access. DG-03, DG-05 and DG-04 remain the owner's decisions before P2.1, P2.3/P2.4 and P2.5.

DG-03 owner decision, 2026-10-18 (`docs/gates/P2.1/dg-03-decision-request.md`; recorded by the writing agent at the owner's instruction):

- **ACCEPTED:** opaque Lockstep-issued `RepositoryId` (D-3.1a); main-worktree-only registration with filesystem-aware canonicalization, no blind case-folding (D-3.2a amended); refuse competing ownership of the same physical Git common directory or the same authoritative remote, while shared ancestry/root commits do not establish identity and forks/template-derived projects stay eligible (D-3.3d, new); remote normalization distinguishing the authoritative remote from upstream/template remotes (D-3.4); one active Engineer per repository and one repository per Engineer (D-3.5a); release/relocation deferred (D-3.6); identity observed from the Engineer's filesystem view (D-3.7).
- The owner's instruction: resume P2.1 and continue through the Phase 2 handoff; no Phase 3.

DG-05 and DG-04 owner decisions, 2026-10-18 (`.local/plans/phase-02_update1.md`; recorded by the writing agent at the owner's instruction):

- **DG-05 ACCEPTED with clarifications** (`docs/gates/P2.3/dg-05-decision-request.md`): D-5.1a through D-5.11 as recommended; exceptions are work-scoped with no time-based expiry by default; no urgency class and no automatic preemption in Phase 2. Clarifications: (1) prerequisites to execution are distinct from gates for later transitions or completion, and evidence producible only during execution must not block initial scheduling; (2) a later layer may not silently weaken a gate's applicability, verifier, required evidence or approval authority, and composition is refused when strengthening cannot be proven; (3) queued work is not an active repository reservation, and exclusive ownership is kept wherever a reservation genuinely exists; (4) a non-behavioural classification cannot evade mandatory tests and must follow authorized policy with evidence.
- **DG-04 ACCEPTED with binding safety requirements** (`docs/gates/P2.5/dg-04-decision-request.md`): D-4.1 through D-4.9 as the foundation, subject to requirements 1–8 recorded there. The Phase 1 no-op dispatcher stays unchanged; its lease rule does not authorize external-effect replay.
- The owner's instruction: proceed sequentially through P2.3–P2.9; keep `lockstep open`; no remote access; no Phase 3.

Phase 2 acceptance, Gate B disposition and Phase 3 authorization, 2026-10-25 (`.local/plans/phase-03.md` §1, sha256 `d6dafdf2…d0c8`; recorded in `docs/gates/B/decision-packet.md` by the writing agent at the owner's instruction):

- **P2.1–P2.9 engineering implementation ACCEPTED** by the owner, against Gate B report r2 (sha256 `3170fa2c058e16070649e8da2825b1308501f646c72b6b310668e720c5fcd91f`, verified before recording) and tested commit `6ba66f5`.
- **Gate B is not passed as a whole.** The machine qualification keeps its recorded results (B1 run 4, 19/19); the human browser walkthrough is **DEFERRED / NOT_RUN** and moves into the revised Gate C as scenario C8. Every earlier Gate B report, review, finding and evidence file is kept unchanged.
- **Revised Phase 3 authorized** (P3.1–P3.11, "The Usable Product Foundation"; exit: revised Gate C — Usability and Operator Readiness), by the owner's explicit change of the gate sequence. The original Phase 3 engineering-execution scope becomes the phase after Gate C, with its safety requirements intact. It authorizes no live model inference, AI-written production code, autonomous Git commit/push/merge, remote access, email approval or external integration (handoff §8).
- Not decided by the handoff and still open: the Gate B packet's effect-key rule (3), unacknowledged abandonment (4), authority by command (5) and the operator installation (6).

DR-P3.1 owner decision, 2026-10-25 (`docs/gates/P3.1/owner-decision.md`; Planner disposition `.local/plans/phase-03_update1.md`; recorded by the writing agent at the owner's instruction):

- **Bootstrap architecture APPROVED:** a containerized control pane without the Docker socket; a narrow host helper running as the invoking OS user, with a private authenticated channel, a fixed versioned allowlist, replay protection, serialized execution, bounded timeouts and durable results. The helper is a **narrow exception** to the earlier no-new-daemon preference, not a general privileged service.
- **Browser authentication for the control pane:** one-time fragment token, per-origin header session credential (no cookie), digests only on the server; exact Host/Origin, CSP and cross-origin protections kept. Migration of the main application is **deferred to P3.4**.
- **Existing cookie pages and their frozen tests preserved**; their retirement is planned at P3.4 through separately authorized frozen-test amendments. Their mechanism is not used for bootstrap management.
- One-time terminal bootstrap build; PATH change only with explicit consent and the user's actual shell; automatic start only of already-compatible services; new root `lockstep` launcher with frozen scripts preserved; minimal first-party JavaScript in P3.1 (pinned HTMX later).
- PRD v0.3 §8 names this decision **DG-15** (P3.1 only).

Governing documents v0.3 and Bible alignment, 2026-10-25 (approval record `LS-V2-DOCS-0.3-APPROVE-2026-10-25`; recorded by the writing agent at the owner's instruction):

- **APPROVED by the owner:** Implementation PRD v0.3 (sha256 `519348e1…a6175bfd`), Dependency-Aware Plan v0.3 (`d017a29d…74b10b42`) and the Bible amendment **LS-BIBLE-2.2-ALIGN-01** (PRD v0.3 §2). The ratified Bible v2.2 (`bbaddf28…6ebb018f`) is the current constitution. Repository records: `docs/PROJECT_BIBLE.md`, `docs/prd/`, `docs/plans/`; registers: `SOURCE_REGISTER.md`.
- Phase 3 exits at **Gate C-UX** (scenarios UX-C1 … UX-C9); the former Phase 3 ticket-to-code transaction is **Phase 4 / Gate C-EXEC** (old C1/C2/C3 keep their meaning there). DG-06 and DG-07 now apply to Phase 4.
- New gates recorded as defined in PRD v0.3 §4 and §8: **DG-14** (email approval authentication; OPEN, before any email action authorization), **DG-15** (= DR-P3.1, ACCEPTED above), **DG-16** (Phase 3 browser-managed effects: verified helper protocol and authorization, privilege separation, operation locks, durable results, no shell injection; to be met by P3.2–P3.3 Contracts), **DG-17** (Phase 4 live coding confinement; OPEN, hard precondition to live consequential work).
- The approval authorizes no agent code execution and asserts no gate passed.

DG-02 does **not** block P1.1 (it blocks P1.2). DG-03…DG-13 block later phases
only; they remain `OPEN` by design and must not be guessed now.

## Accepted human directions already on record (not gates)

From Bible v2.1 §3.6, §36 and §42 item 7 (human-owner decisions through
2026-10-14). Recorded as given. Bible v2.1 itself was adopted as governing at Gate P0
(2026-10-16):

- Haskell rebuild on Launchpad; WAI/Warp, Orb, Beeline, Brigid, HTMX, Orville, PostgreSQL.
- Custom Lockstep CSS replaces Pico; targeted SortableJS permitted.
- Pure Haskell decision core by default; Mercury optional.
- One Engineer per repository; no parallel production-code Implementers.
- Python `AugmenTab/lockstep` at `8b045edb` is a read-only behavioral reference.
