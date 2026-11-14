# LOCKSTEP V2 — PHASE-ORDERED, DEPENDENCY-AWARE IMPLEMENTATION PLAN
## Revision 0.4 — continuous single-Engineer execution; Caesura Gate D

**Document ID:** LS-V2-DAP  
**Date:** 13 November 2026  
**Status:** **APPROVED — HUMAN OWNER RATIFIED, 13 NOVEMBER 2026**  
**Constitution:** ratified Project Bible v2.3 amendment, retaining ratified v2.2  
**Requirements:** approved Implementation PRD v0.4; v0.3 approved and v0.2 incorporated baseline preserved  
**Authority:** The owner approved this revision and the stated D6 policy directions on 13 November 2026. This document does not itself authorize Phase 6 execution, provider usage, privileged host changes or remote publication. Those remain separately governed.

# 1. Executive decision and implementation frontier

**The next objective is one continuously productive Engineer, not another infrastructure redesign.** Phase 4/C-EXEC proved the provider-backed coding transaction, Phase 5/VM-1 proved ordinary development and trusted verification inside separate Dev Capsules, and stabilization S1–S4 addressed authentication renewal, optional reproduction, ineffective retries, review scope and login continuity.

**The missing product capability:** Start from an approved Caesura PRD, derive a dependency-ordered engineering program, authorize it once, and have Lockstep repeatedly choose and execute eligible Work Units without a human manually creating a queue or clicking Continue between every independent engineering increment.

The human remains architect and reviewer. The deterministically scheduled, single-writer Engineer supplies the development throughput. A changed architecture, irreversible external effect, ambiguous side effect, budget exhaustion, or human judgment request still stops only the affected dependency path as appropriate.

## 1.1 Source-to-evidence discipline

- Ratified Bible v2.2 and approved PRD/Plan v0.3 remain historical governing records; v2.3/v0.4 were ratified 13 November 2026. Original completed Contracts, Git, work and event IDs retain their identities.
- The PRD v0.3 incorporates 57 FR and 14 NFR from v0.2. Their original text is not supplied in the current source package. The updated revision incorporates the same requirements and must verify ID collisions before canonical publication.
- No remote publication or live provider usage follows from approving a design document unless separately, explicitly within the specific handoff's authorized action envelope.
- P6 implementation remains one production-code-writing Implementer per repository, sequential through dependency edges; independent **read-only** review and documentation assistance may be parallel only where their authorized boundaries are explicit.

# 2. Phase map: original vs revised

| Revised phase | Original v0.3 phase | Deliverable | Gate / status |
|---|---|---|---|
| P0 | P0 | Adoption and decisions | Historical |
| P1 | P1 | Haskell/PG foundation | Gate A accepted |
| P2 | P2 | Kernel, policies, durable effects | Engineering accepted; Gate B walkthrough deferred |
| P3 | P3 | Trusted local UI and operator controls | C-UX accepted with UX-C8/C9 deferred |
| P4 | P4 | Real single-Engineer coding transaction | C-EXEC accepted |
| **P5** | New | **VM-backed Dev Capsules**, trusted verification, Brigid bugfix, stabilization | **VM-1 accepted**, real native OAuth renewal evidenced |
| **P6** | old P5 | PRD/backlog → durable DAG → approved continuous engineering; Human Inbox and Scribe | **D** + Caesura |
| P7 | old P6 | Multiple independently owned Engineers, deterministic resource admission | E1 |
| P8 | old P7 | GitHub PR/review/rework/integration | E2 |
| P9 | old P8 | External Jira/Shortcut synchronization and reconciliation | E3 |
| P10 | old P9 | Skills, evaluation, human-controlled learning | F1 |
| P11 | old P10 | Restricted Red Team and authenticated bidirectional email | F2 + email |
| P12 | old P11 | Resilience, notifications, packaging, Vacation Day Test | F3 |

**No bulk renaming** of historical Contract IDs, database rows, frozen tests, Git commits or past phase receipts. Old phase labels embedded in historical documents remain accurate for their historical release. Use this crosswalk only for new scope.

# 3. Critical dependency graph

```text
Already qualified:
  P4/C-EXEC ──► P5/VM-1 ──► Stabilization S1–S4 / S1-SD1
                                  │
Proposed work:                    ▼
  P6.1 canonical backlog + source identity
     ├─────────► P6.2 project command center
     └─────────► P6.3 Human Inbox + durable decisions
                         │
                         ▼
  P6.4 PRD/architecture ► versioned Master Plan / Work DAG (DG-08)
                         │
                         ▼
  P6.5 deterministic continuous scheduler + authority envelope (D6-AUTH)
                         │
         ┌───────────────┴────────────────┐
         ▼                                ▼
  P6.6 Profile parity             P6.7 local technical progression,
                                   invalidation + human Done
         └───────────────┬────────────────┘
                         ▼
  P6.8 evidence Scribe ──► P6.9 improvement proposals
                         │
  P6.10 host-enforced unattended capsule safety + real capsule recovery
                         │
                         ▼
  P6.11 model-free linked-work Gate D system qualification
                         │
                         ▼
  P6.12 separately authorized real Caesura dogfood / human Gate D
                         │
                         ▼
  P7 multiple independent Engineers (E1) → P8/P9 → P10/P11 → P12 (F3)
```

The diagram shows the principal critical path, not permission for code-writing concurrency in one repository. P6.10 may be independently prepared early, but no unattended Caesura execution occurs before it qualifies. PRD and external-ticket sourcing are distinct upstream entries to the same Work Unit pipeline.

# 4. Phase P6 — full subphase plan

## P6.1 — Canonical project backlog and source intake

**Dependencies:** P5 accepted; P3 task CRUD and P4 Ticket/Work Order engine.  
**Implement:** First-class Ticket source identity and provenance, backlog views, source ownership and stable idempotency. A plan-derived subphase and internal bug Ticket must generate the same core Work Order/Work Unit shape. Introduce a canonical read-only external import interface. Scope a thin Jira/Shortcut source connector per D6-SOURCE decision; protect connection credentials outside guests. Do not introduce external writeback or PR status synchronization here.  
**Tests:** duplicate imports, missing issue, conflicting source ownership, blocker translation, stale revision, unrelated source not granted execution authority, no cloned scheduler.  
**Exit:** A real internal Ticket and offline external-source fixture import share the engine without granting implicit execution.

## P6.2 — Personal command center for multi-run plans

**Dependencies:** P6.1 and accepted P3/P4 activity/evidence UI.  
**Implement:** Project overview with active plan, dependencies, eligible/blocked work, status at each Work Unit, effective Profile, current capsule, resource/usage state, accepted local commits, human decisions and explicit external-publication absence. Restore page after operator reauth. Exact evidence drilldowns remain available.  
**Tests:** browser restart, stale view, distinct `TECHNICALLY_VERIFIED`/`HUMAN_DONE`/`PUBLISHED`/`INTEGRATED`, keyboard navigation, truthful timeouts, future-eligible vs queued.  
**Exit:** Operator sees what the Engineer is doing and exactly why a task cannot advance, without reading internal logs.

## P6.3 — Human Inbox and durable Planner clarifications

**Dependencies:** P4.3 durable conversations, P4.15 human decisions, P6.2.  
**Implement:** Authenticated revision-bound Human Requests, ordered messages and bounded Planner clarifications. Legal actions are typed and checked by Supervisor, not inferred from chat/email text. Clarification cannot resume work. Work unrelated to the request may continue where dependency-safe.  
**Tests:** reply replay, stale revision, forged principal, two simultaneous requests, duplicate effect, late Planner answer, permission escalation, browser expiry and resumed same page.  
**Exit:** Human decision/clarification loop works in-app without requiring email transport or impersonating owner approval.

## P6.4 — PRD import, Master Plan, graph validation and freeze

**Dependencies:** P6.1, P6.3; owner DG-08 design resolution.  
**Implement:** Planner-assisted interpretation of owner-provided PRD and existing architecture into versioned Phases, Subphases and dependencies. Require explicit source citations, planned deliverables, likely Profile, expected check, external-effect authority and uncertainty ledger. Plan graph validates DAG acyclicity, references, repository ownership, constraints and stable identifiers. Human approves one coherent plan revision and authority envelope. Just-in-time Work Unit Contracts elaborate the frozen outline without rewriting approved architecture.  
**Tests:** missing source, cycle, dangling dependency, invalid graph revision, unapproved rewrite, conflicting project constraints, long-lived PRD after browser restart, Plan vs Ticket parity.  
**Exit:** An approved DAG is durable, navigable and immutable in its authorized aspects; an unapproved plan cannot dispatch code.

## P6.5 — Continuous dependency-driven Scheduler

**Dependencies:** P6.1 and P6.4; D6-AUTH owner decision; P2 Scheduler/effect safety.  
**Implement:** Event-driven readiness recomputation after technical settlement, changed prerequisites, resource availability, owner decisions and restart. No separately approved execution queue. Scheduler deterministically chooses one ready Work Unit from the approved graph under Profile, Git basis, capacity, budget, priority, resource and idempotency constraints; claims before launching. Continue automatically to the next eligible Work Unit at a safe boundary. Stop the affected path when authority or proof is missing.  
**Tests:** initial ready set, multiple ties, hidden blocked descendant, priority cannot bypass dependency, two contenders one claim, crash before/after settlement, idempotent replay, unknown provider quota, no additional queue-click required.  
**Exit:** Three scripted dependent Work Units progress automatically after one plan approval; no new Implementer swarm, no duplicate claims.

## P6.6 — Greenfield/brownfield Profile parity

**Dependencies:** P2 effective Profiles, P6.4, P6.5.  
**Implement:** Profile selection by project type/risk and inherited universal invariants, with visible version/digest and allowed strengthening. Preserve mandatory frozen tests, independent challenge/review, constraints and bounded retries; choose correct plan/test/repository policies for Caesura greenfield development.  
**Tests:** precedence, unauthorized downgrade, hidden exception, incompatible test profile, false non-behavioral classification.  
**Exit:** Profiles affect authorized Work Units deterministically and never bypass universal safeguards.

## P6.7 — Phase integration, provisional progression and human authority

**Dependencies:** P6.5, P6.6, existing Supervisor Git and Human Done.  
**Implement:** Distinct durable statuses for local technical acceptance, final Human Done, and publication/integration. Under an approved envelope, locally verified provisional completion satisfies declared *technical* dependencies; no owner Done per unit is needed to continue. Owner rejection of an ancestor invalidates its transitive descendants and stops affected active paths at safe boundaries. An irreversible effect is never enabled by provisional status. Make repository health, work-branch basis and reconciliation explicit.  
**Tests:** nonblocking local chain, rejection and transitive invalidation, unrelated branch unaffected, late reviewer finding, stale plan, external-effect authority denial, ancestor rework restoring eligibility only with fresh evidence.  
**Exit:** Automatic progression does not surrender final human authority or conceal dependent work invalidation.

## P6.8 — Evidence-linked read-only Scribe

**Dependencies:** P6.2, P6.7.  
**Implement:** Deterministic summary selection from canonical records, with optional read-only Scribe explanation. Report planned/completed/waiting/provisional/Done, source revision, test and review result, token usage breakdown where available and owner-intervention counts. Scribe cannot produce new authorization, canonical change or fictitious success.  
**Tests:** no-run vs pass, uncertain effect, stale summary, fabricated report claim, change citation mismatch, no cost dollars invented from subscription usage.  
**Exit:** Owner can return and understand evidence-backed progress and decisions without examining terminal transcripts.

## P6.9 — Human-controlled improvement proposals

**Dependencies:** P6.8 and current challenge/review evidence.  
**Implement:** Typed change proposals to Profiles/Skills/engineering practices, from recurring failures, test inadequacy and human corrections; explicit approver, impact, evidence and refusal. **Do not** auto-install improved prompts, agent permissions or global policies.  
**Tests:** duplicate proposal, forged approver, stale proposed revision, auto-install denied, personal-vs-professional isolation.  
**Exit:** Useful learning proposal channel exists without self-modifying agent authority.

## P6.10 — Host-enforced unattended capsule safety and recovery gate

**Dependencies:** P5 Capsule Runtime; may be prepared independently while P6.1–P6.9 proceed. Hard predecessor to *unattended* Caesura and general overnight use.  
**Implement:** Replace attended-only LAN exceptions with a **host-enforced**, guest-root-resistant boundary for the Mac's protected interfaces and management services. Preserve public package access and host-to-guest control channels through narrowly permitted paths. Add guest image digest pinning and provenance checks. Qualify no unintended access to host Docker, provider credentials, Git authority or another capsule. Verify helper/service/host interruption and resumed state, including at least two capsules coexisting without crossing projects (do not require parallel code writing within one repo).  
**Owner boundary:** An OS `pf` rule, privileged network setup or host installation needs specific human authorization. Do not run `sudo`, install host tools, silently block unrelated network services or fall back to an unattended listener exception. Draft and test nonprivileged fixtures first.  
**Tests:** explicit network allow/deny and bypass attempts, service appears after startup, guest root reconfigures its firewall, host reboot/VM crash, simultaneous capsule isolation, pinned-image mismatch, normal public dependency fetch.  
**Exit:** Unattended local execution can proceed without making host LAN services reachable to untrusted guest code. Record actual host-specific qualification, not only mocked firewall syntax.

## P6.11 — Model-free Phase D qualification

**Dependencies:** P6.1–P6.10.  
**Implement:** Real PostgreSQL, real Git, real service UI and actual Dev Capsule runs with scripted Planner/Challenger/Implementer/Reviewer role documents. Include the source connector's offline fixture and durable Human Inbox. Freeze at least three linked Work Units and prove automatic next-ready scheduling. Introduce crash, budget, authority and owner rejection faults. No provider tokens required.  
**Tests:** All PRD v0.4 D-01–D-11; complete clean-clone suite, relevant live-isolation (synthetic), negative Git/test tamper, and browser user journeys.  
**Exit:** Full plan-driven transaction progresses without artificial queue authorization, false verification or owner Continue prompts, and every negative case refuses correctly.

## P6.12 — Caesura dogfood and owner Gate D

**Dependencies:** P6.11, separately approved model usage and Caesura PRD/milestone, host-enforced unattended security.  
**Implement:** Import actual Caesura PRD/architecture; Planner builds a DAG; owner approves plan and bounded authority once; run at least three dependency-linked Work Units with real model sessions inside Caesura's development VM, real RED/GREEN checks, independent challenge/review, Supervisor-controlled commits and observable progress. No cloud publication, deployment or secret sharing without its own approval. Human reviews milestone, final Done and Gate D evidence.  
**Success evidence:** reproducible buildable feature milestone, exact DAG/plan versions, source-grounded Contracts, tests, commit graph, real session usage and interventions, automatic advancement, safe halts and resumption. A canned three-item queue, three trivial commits or a manually nudged sequence is **not** proof.  
**Exit:** Owner explicitly accepts Gate D on actual Caesura multi-unit progress; optional UX-C8/C9 remains separately deferred unless specifically tested.

# 5. Phase 6 critical tests and negative evidence matrix

| Threat or failure | Must demonstrate |
|---|---|
| Unapproved graph | Scheduler dispatches nothing, regardless of high priority |
| DAG cycle or missing edge | Planner approval blocked with exact conflict; no silent edge deletion |
| Dependencies vs priority | High-priority blocked child cannot outrun required predecessor |
| Double claims or watcher restart | Exactly one canonical writer and one durable claim |
| Provisional verified local work | Eligible descendants proceed under the approved envelope; `Human Done` remains unchanged |
| Human rejects an ancestor | Transitive descendants invalidated; unrelated branches unaffected; no secret rollback of irreversible effects |
| Reviewer incomplete scope / test bypass | No accepted local change; protected frozen criteria still Supervisor-held |
| Provider quota/expired auth | Finite, evidence-backed retry or halt; `UNKNOWN` not guessed as available |
| Changed source revision / stale plan | Compare-and-swap refusal, fresh authorized revision required |
| Planner's unsolicited scope change | Escalate architecture decision; frozen plan unchanged |
| Process/helper/service restart | No duplicate dispatch, lost decision, fake completed step or blind effect replay |
| Guest network/host credential | No unauthorized host LAN/socket/credential reachability; guest public dependency fetch still works |
| User closes browser or login expires | Work continues; exact pending decision survives and can be revisited |
| Scribe or external adapter misreports state | Canonical engine state prevails; writeback cannot self-authorize |

# 6. Phase D governance decisions and authority envelopes

Before freezing a P6 Work Unit Contract that depends on these policies, obtain an explicit owner decision:

- **DG-08:** Plan approval/freeze/revision semantics, including immutable versus just-in-time refinable graph elements.
- **D6-AUTH:** Exact permitted progression from technical acceptance to dependency readiness without Human Done, with local-only provisional authority, invalidation, and forbidden irreversible effects.
- **D6-SOURCE:** Thin real read-only Jira/Shortcut source adapter now versus export/import only until P9; recommend the former for genuine two-mode onboarding, but do not block the PRD Caesura gate on unattached credentials.
- **D6-SEC:** Host-enforced LAN protection implementation/OS privileges, image provenance and concurrency/host-restart qualification for unattended execution.
- **D6-GATE:** Predeclare Caesura milestone scope, number of dependent units, human-intervention budget, evidence and finite real-provider budget before live trial.

**No implementation agent may ratify an owner gate.** An authorization envelope must be recorded with project ID, plan revision/digest, allowed Work Units and changed-file policies, effective Profiles, local vs external effects, resource/usage limits, environment/network trust, optional provisional progression and review/Done obligations.

# 7. Phases P7–P12 — retained detail and primary dependencies

## P7 — Multiple independent repository-bound Engineers (E1)

Five original v0.3 P6 subphases become P7.1–P7.5: persistent Engineer ownership; provider account separation and native auth; reliable quota/availability observations; global deterministic resource admission/fairness; two-repository E1 full qualification. **Hard preconditions:** Gate D, P6.10 host network boundary, no cross-capsule tokens/Git, two active capsule test, no parallel production writers *within* a repository. Five or more Engineers is a scale target to benchmark, not a claim current host can run five simultaneous large builds.

## P8 — GitHub PR delivery and review (E2)

Original P7.1–P7.9 become P8.1–P8.9: DG-09 branch/PR mapping, authorized push/PR creation, idempotent external effect dispatch, reviews and change requests, correction Work Order, re-verification, permitted integration, separate `ACCEPTED`, `PUBLISHED`, `INTEGRATED`, `DONE`, real PR E2 test. No automatic publication on provisional verification alone.

## P9 — External Jira/Shortcut bidirectional synchronization (E3)

Original P8.1–P8.5 become P9.1–P9.5: DG-10 field ownership, provider-specific writeback/reconciliation, priority and blocker updates, source-of-truth conflict handling, Scribe tracker publishing and E3 real loop. Reuse Phase 6's canonical imported identity; personal PRD projects must remain independent of Jira/Shortcut.

## P10 — Skills and controlled process learning (F1)

Original P9.1–P9.5 become P10.1–P10.5: versioned Skills, scoped install/evaluation, prompt audits, privacy/licensing-safe sharing, rollback and owner-approved promotion. No agent modifies its own global authority policy.

## P11 — Restricted Red Team and first bidirectional email (F2 + communications)

Original P10 workstreams are retained: P11.1 exact Red Team target scope and risk envelope (DG-12); P11.2 authenticated email adapter and human request correlation (DG-14 before action), P11.3 restricted isolated Red Team worker, P11.4 evidence and finding disposition, P11.5 staging F2. Email messages that cannot prove authorization are informational, never approvals. Independent workstreams may be sequenced flexibly without code-writing swarms.

## P12 — Resilience, packaging, Vacation Day Test (F3)

Original P11.1–P11.6 become P12.1–P12.6: morning Scribe report, notifications, provider/quota and restart handling, GitHub Issues/dependency alerts, predeclared full Vacation Day Trial, and repeatable fresh install/upgrade packaging. **Ratified F3 remains unchanged:** 2–4 independent Engineers, full day, <=5 substantive human email replies (including clarification), zero UI/terminal rescue, meaningful independently verified progress and truthful faults. Five-plus concurrent Engineer ambition is separate capacity work. A silent but unproductive test fails.

# 8. Ratification record and implementation handoff path

1. Ratification review: the owner approved the v2.3/v0.4 governing set on 13 November 2026. Before canonical publication, reconcile the approved PRD v0.4, ratified Bible v2.3, decision register and source register; verify unchanged v0.2 requirement references without fabricating missing text.
2. Record the owner's completed ratification of v2.3/v0.4 and the adopted D6 directions, with exact approved versions and digests, in canonical `docs/PROJECT_BIBLE.md`, `docs/prd/`, `docs/plans/` without rewriting v2.2/v0.3 historical artifacts.
3. Produce a separate **full-phase Phase 6 implementation handoff** on the verified installed stabilization baseline, with contracts, frozen tests, plan decomposition, negative qualification and bounded execution authority. The handoff is the actual implementation authorization, not the governing-document ratification.
4. Execute P6.1–P6.11 in dependency order, keeping the existing production workflow, one writer and project functionality green. Demonstrate model-free multi-unit progress before any Caesura provider trial.
5. Obtain explicit consent for any host OS firewall/admin change, actual provider usage, and the Caesura real milestone. Do not use the expired Brigid LAN exception as a shortcut.
6. Present Gate D evidence to the human owner; only the owner accepts it and marks final Done. Preserve failures, rejected proposals and original receipts.

**Final target:** Caesura makes real, reviewable multi-unit progress while its human technical lead is not operating the Engineer. Continuous execution is a deterministic, bounded capability of the approved plan—not an AI-run company and not a permission to bypass security or human judgment.
