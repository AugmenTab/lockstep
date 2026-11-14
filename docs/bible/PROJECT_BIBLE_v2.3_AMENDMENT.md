# LOCKSTEP — PROJECT BIBLE v2.3
## Ratified governing amendment and consolidation guide

**Document ID:** LS-BIBLE-2.3-01  
**Ratification source:** Approved by the human owner on 13 November 2026 (formerly review document LS-BIBLE-2.3-PROPOSED-01)  
**Date:** 13 November 2026  
**Status:** **RATIFIED — HUMAN OWNER APPROVED, 13 NOVEMBER 2026**  
**Baseline authority:** Project Bible v2.2 FINAL, ratified 25 October 2026; amendment LS-BIBLE-2.2-ALIGN-01, approved with PRD/Plan v0.3.  
**Paired governing editions:** Implementation PRD v0.4 and Dependency-Aware Plan v0.4, approved 13 November 2026.  
**Preservation rule:** The complete 75-page ratified v2.2 PDF is preserved verbatim as the historical source in the companion consolidated PDF. This amendment expressly qualifies or supersedes only the clauses identified below. All other v2.2 provisions, including the original diagrams and Vacation Day Test requirements, retain force.

> **Not an implementation receipt.** Ratification of this edition does not, by itself, authorize Phase 6 execution, external effects, provider spending, or host administration; it does not self-accept any gate, modify an accepted Contract, or declare future functionality complete. The human owner approved this edition and the D6 policy directions on 13 November 2026. Accepted results recorded in the decision register retain their original dates and source evidence.

## 1. Constitutional direction — what Lockstep actually models

**B23-01 — A disciplined Engineer, not a simulated company.** Lockstep models the successive cognitive responsibilities of *one disciplined software engineer*: understand a problem, plan, define correctness, implement, test, independently challenge the result, and present evidence. It replicates that workflow across independently owned projects. It does **not** simulate a startup, invent LLM management layers, or permit multiple Implementers to write production code concurrently in a repository. This clarifies Bible §§1, 3.1–3.3, 31 and 40; it preserves the approved v2.2 replacement for §3.1 item 1.

**B23-02 — The human is technical lead.** The human primarily defines product requirements, chooses architectural constraints, approves the bounded execution plan, reviews work, and decides consequential exceptions and final Done. Routine work selection, build commands, dependency installation, compiler troubleshooting, bounded recovery and status reporting should not require the human to operate the agent. This clarifies §§2, 3.1, 11–13, and 39. It does not delegate human risk acceptance.

**B23-03 — Front-load engineering judgment.** A project starts with an approved PRD/architecture, a compatible authoritative backlog, or an explicitly bounded single Ticket. Before code-writing begins, the Planner makes dependencies, invariants, acceptance criteria, environmental prerequisites, authority limits and expected evidence explicit. The executable engineering plan should function as a constrained specification. Weak or contradictory inputs are surfaced early; the Implementer does not silently substitute architecture.

**B23-04 — Deterministic control plane.** The existing Supervisor/Scheduler owns the canonical state machine, scheduling, resource admission, recovery, authority, Git and evidence. The **Capsule Runtime** is deterministic VM infrastructure; it is not an LLM, agent-manager or second scheduler. Agents may perform bounded engineering reasoning but cannot instantiate other Engineers, invent privileges, self-certify their work, or change approved policies.

## 2. Dev Capsules — the qualified execution substrate

**B23-05 — Development environment is a first-class resource.** A **Dev Capsule** is a persistent, isolated Linux VM assigned to a repository-bound Engineer, not a transient tool invocation. Its guest owns the writable workspace, compiler/package caches, project-defined tools, shell, local servers and guest Docker Engine/Compose. Scripts, pipes, multiline shell, package installation and normal compilation are permitted within the capsule; brittle command-syntax prohibitions are not an acceptable substitute for isolation. This prospectively updates the execution-substrate expectations of §§3.2–3.3, 35, 38–39 without undoing Phase 4 evidence.

**B23-06 — Provider credentials never enter untrusted execution.** Authenticated provider CLIs reside outside the guest trust boundary. Model-directed project tools execute through a bound, policy-enforced guest bridge. Guests have no host Docker socket, keychain, provider auth volume, Supervisor credentials, canonical Git authority, or unrelated project mounts. Native provider subscription authentication remains CLI-owned, over end-to-end TLS. An ordinary development tool may be unrestricted *inside its guest* without acquiring host authority.

**B23-07 — Development and verification do not share mutable trust.** One persistent writable Engineer VM does not imply a second permanent Engineer. Independent deterministic verification uses a trusted, project-compatible reconstructed environment with Supervisor-held frozen tests, candidate content and authoritative outcomes. A compromised Implementer VM cannot forge success using an altered compiler, test runner, Git metadata or leftover process. Verification VMs may be pooled or stopped when idle only if isolation and clean reconstruction are proved.

**B23-08 — Resource governance and scale.** Multi-project concurrency is across distinct owned repositories only, with deterministic CPU, memory, disk, provider quota and verification-capacity admission. Five or more registered Engineers is a product scaling goal, not a presently proven host capacity or a waiver of the one-writer rule. An idle capsule need not remain running. VM provisioning, restart and failure reports must be observable and recoverable.

**B23-09 — Network trust is enforced outside guest root.** Phase 5's `networkOpts.hostLoopback: false` and scoped expiring listener exceptions qualified an *attended* Brigid run. The exception is not an unattended or multi-project security guarantee. An enforceable host-side boundary for protected LAN addresses/services, bounded public egress policy, and negative qualification are prerequisites before unrestricted unattended/multi-project execution. No guest-managed firewall counts as host protection.

## 3. Work acquisition and continuous dependency-driven execution

**B23-10 — Two intake modes, one work graph.** An owner may (a) provide a PRD and have the Planner construct a versioned, phase-ordered dependency-aware Master Plan, or (b) connect an authoritative issue/backlog system and have Lockstep interpret its issues, dependencies and acceptance obligations. Locally originated tickets and approved planned subphases share the existing Work Order / Work Unit engine. An external source is optional for personal use and does not require inventing a Phase tree. This clarifies §11; full bidirectional Jira/Shortcut synchronization remains a later milestone.

**B23-11 — The plan *is* the schedule.** Once the owner approves the plan and its **authority envelope**, no separate dependency-ready queue or extra blanket queue authorization is required. The deterministic Scheduler automatically claims the next eligible Work Unit when a safe boundary is reached. Readiness is calculated from dependencies, current source revision, effective Profile, authorization, exclusive writer ownership, environment capacity and external-effect state; priority cannot bypass an unmet prerequisite. The Planner specifies the next unit just in time inside the approved scope. A revised plan is versioned, not silently substituted.

**B23-12 — Continuous does not mean unbounded.** Each invocation, recovery loop, token/time budget and external operation remains finite. The system may continue across authorized Work Units while the owner is away, but pauses the affected path for ambiguous side effects, invalidated dependencies, exhausted budgets, changed architecture, required human risk acceptance, or unsupported environment. Recovery and replanning do not become new authority. No blind replay of uncertain effects.

**B23-13 — Nonblocking technical progress with human sovereignty.** Preserve three distinct notions: **technically verified/accepted locally**, **human final Done**, and **externally integrated/published**. For work within an approved plan and explicitly permitted to advance provisionally, independently verified local results may unlock dependent local engineering work **without requiring a separate human Done click after every Work Unit**. The human retains final Done and may reject that work. Rejection must halt affected descendants, mark their evidence and assumptions as invalidated, and require explicit reconciliation or rework; the Scheduler may never hide descendants or presume a safe rollback of external effects. No irreversible push, merge, schema migration, deployment, destructive action or high-risk policy change acquires authority from provisional progress alone. This is a *ratified prospective policy refinement* of §§3.1, 9, 11–13 and 39, not a retroactive change to historical human-Done Contracts.

**B23-14 — Genuine escalation only.** The Planner resolves normal implementation uncertainty and repairs within the approved Contract and budgets. A Human Request is appropriate for product/architecture changes, consequential security or cost tradeoffs, irreversible effects, conflicting external authority, and ambiguous effects requiring judgment. Human Inbox records exact identity, scope, revision and legal actions. Clarification content cannot authorize an effect. Status and morning briefings must distinguish waiting for human, retryable environment failure, budget exhaustion, inconclusive review and true acceptance.

## 4. Verification and engineering quality

**B23-15 — The intended Verifier's two duties.** The future independent, read-only **Verifier** checks: (1) conformance to the *owner-approved* architecture, domain model, library/typing standards and Contract; and (2) the integrity and meaning of Planner-defined tests against weakening, bypasses and reward hacking. Supervisor deterministically proves byte-level frozen-test preservation; the Verifier assesses semantic circumvention. The Verifier cannot write code, author a new baseline, change the Contract or approve its own work. Verifier findings cite exact requirements and evidence. Until a separate role-transition Contract is authorized, Phase 4–5's existing Challenger/Reviewer roles remain in production. This clarifies §§3.2, 28–34; it does not silently retire DG-07.

**B23-16 — Architectural standards are explicit, not aesthetic.** Haskell domain identifiers and states should carry their meaning through Kernel, Application, Persistence and Web where appropriate. Approved Launchpad/Artificer patterns and `STACK_PATTERNS.md` provide evidence for future architectural conformance. The unfinished type-field inventory, Orb route/handler work and other V3 restructuring remain deferred. Phase 6 is not blocked by stylistic cleanups unrelated to demonstrated safety or functionality.

**B23-17 — Project-convention-aware tests and complete review.** Planner-authored tests must use the repository's actual test framework and relevant conventions, test behavior beyond one hardcoded case when proportional, and establish valid RED. The read-only Reviewer must report a complete inspected-file scope; an incomplete or unsupported review cannot be called approval. The Supervisor continues to protect frozen tests and canonical Git independently.

## 5. Evidence, human experience and economics

**B23-18 — One source of execution truth.** Installed code, Git objects, durable state, authorization records and independently observed execution results—not model assertions or a retrospective's prose—establish whether work ran. Captured provider usage distinguishes input, output, cache writes and cache reads when available; subscription usage is not assigned invented API-dollar costs. Work Units and dependency edges retain exact source revisions, plan/version, evidence links, retries and elapsed time.

**B23-19 — Operational autonomy is a product property.** Track avoided and required owner interventions per Work Unit and per plan: initial plan approval, legitimate architecture decisions, final Done, redundant prompts, manual environment setup, useless retries and manual rescue. Success at one real transaction does not automatically establish unattended project execution. The owner should spend attention on product design and review, not managing agent shells.

**B23-20 — Caesura is the Gate D dogfood.** Gate D should include a real multi-Work-Unit Caesura milestone generated from an approved PRD, with dependent work progressing without individual Continue clicks. The human reviews a meaningful application result and evidence; trivial queue processing alone is insufficient. Caesura's product requirements, acceptable milestone and permitted effects must be frozen before the trial. No undocumented content or production integration is assumed.

## 6. Milestone interpretation and accepted history

This section is an explicit **prospective** map, not a rewrite of the original §§38–40 or past receipts.

| Milestone | Current meaning | Recorded status |
|---|---|---|
| A | Haskell/PostgreSQL initial service | Historical acceptance preserved |
| B | Kernel/ownership/effects substrate | Engineering accepted; human Gate B browser walkthrough `NOT_RUN / DEFERRED` |
| C-UX | Trusted local UI and human usability | Accepted with UX-C8/C9 explicitly deferred |
| C-EXEC | Real subscription-backed single-Engineer coding | **Accepted** after calculator smoke |
| VM-1 | VM-backed Dev Capsules; real Brigid transaction | **Accepted** 13 Nov 2026; Brigid Human Done recorded |
| Stabilization S1–S4 | Authentication reliability, reproduction/retry, test/review, session continuity | Offline accepted; installed build and real provider renewal evidenced separately |
| D / P6 | Continuous PRD/backlog-based work graph and safe autonomous progression | Future, not implemented |
| E1–E3 | Independent repositories, GitHub delivery, tracker synchronization | Future |
| F1–F3 | Skills, scoped Red Team/email, Vacation Day Test | Future |

**Evidence precision.** The Phase 5 Brigid proof used accepted commit `73b0203`, frozen tests `cd0c17f`, and explicit Human Done. The stabilized service was reported installed at `d00e26c`; a real native OAuth renewal was observed in two authorized short sessions, but not through an ordinary service transaction. Prior published commits, backup receipts, platform limitations and deferred UX-C8/C9 do not become more or less accepted because this Bible is revised.

## 7. Revised phase mapping (prospective)

| Older v0.3 plan | Approved v0.4 plan | Scope |
|---|---|---|
| P0–P4 | P0–P4 unchanged | Historical accepted work |
| new P5 | P5 completed | Dev Capsules / VM-1 and post-P5 stabilization |
| old P5.1–P5.10 | **P6.1–P6.10, augmented** | Plan/backlog parity, continuous scheduler, Human Inbox, Scribe, Gate D and Caesura |
| old P6.1–P6.5 | P7.1–P7.5 | Multiple independently owned Engineers, E1 |
| old P7.1–P7.9 | P8.1–P8.9 | GitHub E2 |
| old P8.1–P8.5 | P9.1–P9.5 | External tracker E3 |
| old P9.1–P9.5 | P10.1–P10.5 | Skills F1 |
| old P10 Red Team/email | P11 | Restricted security work and email, F2 |
| old P11 | P12 | Resilience/Vacation Day, F3 |

The approved v0.3 PRD/Plan and their original numbering remain historical source documents. New numbering must not change persistent Contract IDs, recorded events, gate receipts, or migration history. The exact project scheduling, approval and provisional-work semantics are specified in the approved PRD v0.4 and Dependency-Aware Plan v0.4.

## 8. Ratified policy decisions and explicit non-goals

The owner approved the following D6 policy directions on 13 November 2026. Implementation-specific Contracts and any separately named gates still require their stipulated authorization:

1. **D6-AUTH:** One approved plan/authority envelope permits automatic local dependency-ready progression; local verified work may provisionally unlock descendants while final human Done remains distinct and consequential external effects remain human-gated.
2. **D6-SOURCE:** Phase 6's minimum external-source capability: at least a read-only provider-specific intake for a configured Jira/Shortcut source, or a bounded export/import path with live provider integration deferred to Phase 9. The approved default in the paired PRD is the read-only provider path where an owner-authorized connection exists; Caesura may use the PRD path and does not require such a connection.
3. **D6-GATE:** Gate D combines model-free multi-Work-Unit execution and a separately authorized real Caesura milestone with no unnecessary owner Continue action.
4. **D6-SEC:** A durable host-enforced LAN boundary and relevant guest-concurrency/restart qualification are required before declaring *unrestricted unattended* execution. Phase 6 planning and model-free scheduling tests may proceed earlier, but unattended Caesura must not use the expired Brigid LAN exception.

**Not authorized by this edition:** V3 domain-model rewrite, multiple code-writing agents in one repository, simulated AI managers, automatic remote Git publication, broad cloud hosting, unsupported provider credential handling, unqualified network exemptions, automatic Skills promotion, or a change to the ratified F3 metrics. The original F3 benchmark stays **2–4 independent Engineers, a predeclared full day, at most five substantive human email replies, zero UI/terminal rescue, and meaningful independently verified progress**.

## 9. Document authority and publication

Ratified by the owner on 13 November 2026, this amendment is the v2.3 interpretive overlay on the preserved v2.2 Bible. Ratification is not a claim that canonical repository documents have been edited or published. The approved text should be committed with a source register, decision record, exact digest and links to the approved PRD/Plan v0.4 revisions.

**Companion PDF construction:** front matter and this v2.3 amendment appear before the full, unmodified 75-page v2.2 PDF. The latter is a historical annex retaining its original visual authority and source wording; where the original conflicts with this expressly named ratified amendment, the amendment governs prospectively from the owner's 13 November 2026 ratification.
