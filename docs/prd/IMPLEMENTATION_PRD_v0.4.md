# LOCKSTEP V2 — IMPLEMENTATION PRD
## Revision 0.4 — Dev Capsule acceptance and continuous engineering

**Document ID:** LS-V2-PRD  
**Revision date:** 13 November 2026  
**Status:** **APPROVED — HUMAN OWNER RATIFIED, 13 NOVEMBER 2026**  
**Product authority:** ratified Project Bible v2.3 amendment over ratified Bible v2.2 and approved LS-BIBLE-2.2-ALIGN-01  
**Companion:** approved Dependency-Aware Plan v0.4  
**Supersedes prospectively:** PRD v0.3 future phase mapping and work assumptions from owner approval on 13 November 2026; does **not** amend past Contracts or receipts.  
**Requirements preservation:** The v0.3 PRD stated that 57 original FR and 14 original NFR from v0.2 remain normative by incorporation. The full v0.2 source is not supplied here; its unchanged language remains incorporated rather than reconstructed. The complete v0.3 source is reproduced unmodified in the companion PDF as a historical annex and is available in its approved Markdown source.

> **Interpretation:** This approved edition specifies current evidence and future work, not proof of implementation. No new code execution, external effects, remote push, installation, real provider call or human gate acceptance follows automatically from its approval. When a historical requirement conflicts with an *expressly named new requirement below*, the owner-ratified amendment governs prospectively; otherwise original text and safeguards remain in force.

# 1. Product goal and engineering model

Lockstep models the internal disciplined workflow of **one Engineer** and repeats that workflow across separately owned repositories. The human is the engineering lead: design product purpose and architecture, approve the implementation authority envelope, inspect decisions and results, and retain final human Done. Lockstep does not simulate a software startup, contain an LLM manager, or allow parallel production-code-writing Implementers in one repository.

**Near-term product goal:** Take an approved Caesura PRD, construct a coherent implementation DAG and autonomously advance multiple dependent engineering Work Units, producing independently verified, reviewable application progress without requiring the owner to create an execution queue or click Continue after each unit.

The deterministic Supervisor is the only scheduling/authority control plane. The Planner creates and revises bounded engineering plans; the Implementer writes one repository at a time; the current independent Challenger/Reviewer remains in force until a separately approved Verifier transition.

# 2. Historical gate status and evidence discipline

| Gate / increment | Recorded disposition | Meaning / exception |
|---|---|---|
| A | Accepted historically | Haskell/PostgreSQL base and typed command shell |
| B | Phase 2 engineering accepted | Human Gate B browser walkthrough `NOT_RUN / DEFERRED` |
| C-UX | Accepted with explicit exceptions | UX-C8 and UX-C9 remain unperformed; never relabel as PASS |
| C-EXEC | Owner accepted | Real Claude subscription calculator transaction, one code-writing Implementer, frozen tests and Supervisor commits |
| VM-1 / P5 | Owner accepted | Brigid `73b0203`, frozen tests `cd0c17f`, Human Done, isolated development and verification VMs |
| Stabilization S1–S4 | Offline implementation accepted and reported installed | Authentication diagnostics, optional reproduction semantics, Planner/Reviewer discipline, session continuity |
| S1-SD1 | Approved, applied | Exact `api.anthropic.com` and `platform.claude.com` TLS-CONNECT hosts; reported real native renewal through the helper launch path |
| D / P6 | **Not implemented or accepted** | Continuous approved plan execution and Caesura gate |
| E1–E3, F1–F3 | Future | Multi-Engineer, GitHub, tracker, Skills, security/email, Vacation Day |

**Precise state labels are mandatory:** `PASSED`, `FAILED`, `NOT_RUN`, `DEFERRED`, `INCONCLUSIVE`, `BLOCKED`, `UNKNOWN`, `TECHNICALLY_VERIFIED`, `HUMAN_DONE`, `PUBLISHED`, `INTEGRATED`, `INVALIDATED` and `EFFECT_UNKNOWN` must not be presented interchangeably. New product states must map into existing typed Kernel/Supervisor vocabulary through a reviewed Contract, not ad hoc UI strings.

# 3. Requirements — Dev Capsules and current single-Engineer baseline

These are **release obligations already qualified for the accepted Phase 5 scope**, and regression obligations for future phases. Do not reopen implementation merely to rewrite them.

| ID | Testable requirement | Evidence / continued obligation |
|---|---|---|
| FR-CAP-01 | One repository-bound Engineer has a VM-backed, persistent writable development capsule with project-defined toolchain, caches, normal shell and guest Docker/Compose. | P5 real VM qualification; Brigid compiler installation and tests |
| FR-CAP-02 | Dev Capsule cannot read host credentials, unrelated repositories, host Docker socket or provider auth. CLI credentials remain outside guest; model uses bound tool bridge. | P5 negative boundary checks; preserve in every future adapter |
| FR-CAP-03 | Deterministic Supervisor/Capsule Runtime handle lifecycle, allocation, expiry, cancellation and ambiguous effects; no AI VM manager or fallback execution in credential container. | P5 synthetic E2E and recovery; host-reboot and cross-VM scale tests still future |
| FR-CAP-04 | Independent verification reconstructs candidate against trusted frozen tests and suitable project toolchain; neither mutable Implementer VM nor guest Git metadata decides acceptance. | Brigid `RED/GREEN`, Supervisor Git checks |
| FR-CAP-05 | Per-project resource profiles, preflight and isolation are observable and fail closed on unapproved host LAN exposure. | P5 scoped attended policy; host-enforced isolation required for unrestricted unattended use |
| FR-AUTH-01 | Official native Claude Code subscription login and renewal, exact-host TLS passthrough, no token handling by Lockstep and no API-key billing fallback. | S1-SD1 reported real renewal; current CLI endpoint change must be diagnosed and gated |
| FR-OPS-01 | Absent optional reproduction command proceeds to genuine Planner-authored RED candidate tests; retry must target a stage capable of progress. | Stabilization S2; preserve negative tests |
| FR-OPS-02 | Planner follows established project test conventions; Reviewer reports full changed-file inspection or yields incomplete review. | Stabilization S3; scope claim not equivalent to cryptographic proof of reads |
| FR-OPS-03 | Browser login expiry never changes transaction outcome or consumes pending decisions; reauth returns to relevant page. | Stabilization S4 |

**Explicit limitations:** The accepted Brigid LAN exception expired and never granted unrestricted unattended access. The current baseline has not qualified two capsules simultaneously, all host-reboot interruption cases, or every hostile archive fixture. The base guest image is not digest-pinned. These are prerequisites at the dependency edges specified below, not reasons to revoke VM-1.

# 4. New and refined Phase 6 functional requirements

## 4.1 Work intake and canonical plan

**FR-PLAN-01 — Two first-class source modes.** An owner can start a project from (A) a PRD/architecture or (B) a configured authoritative external Ticket/backlog source. A locally created standalone Ticket remains valid without a Master Plan. All routes map to existing canonical Ticket, Work Order, Work Unit, repository ownership and Profile semantics; there is no second execution engine.

**FR-PLAN-02 — Real PRD-to-DAG planning.** The Planner reads PRD, architecture, constraints, existing repository and available tests, then proposes a versioned Master Plan composed of Phases, Subphases, Work Units and typed dependency edges. Every unit records a source citation, expected artifact, acceptance/negative evidence, environment prerequisite, owner, effect class, risk and candidate boundary. Cycles, unknown dependencies, contradictory requirements and unauthorized source changes refuse plan approval with human-readable diagnostics.

**FR-PLAN-03 — Owner approves *one meaningful authority envelope*.** The owner approves a specific plan revision, project/repository, legal operations, environment and network policy, consumption budgets, technical-verification policy, permitted provisional progression and escalation rules. That approval makes eligible work executable; no extra authorizing action is needed merely to create or start a separate queue. Plan changes requiring expanded scope, irreversible effects or changed architecture require a new approval. An approved plan may be locally refined *only* within its envelope; original revisions remain auditable.

**FR-PLAN-04 — Source ownership and external intake.** At least one thin **read-only** provider-specific Jira or Shortcut intake path should be available in Phase 6 when an owner-authorized connection exists, mapping source IDs, blockers and acceptance into the canonical work graph without mutating the external system. A provider-neutral canonical import/export path must work model-free with offline fixtures. Full provider writeback, PR lifecycle and bidirectional reconciliation are Phase 9, not Phase 6. The Caesura Gate D test uses the PRD path and does not depend on an external connection. This scope is adopted under **D6-SOURCE** by the owner's 13 November 2026 approval; use of an external connection still requires its own authorization.

**FR-PLAN-05 — Stable amendments and audit trail.** Every graph revision records provenance, owner approval basis, changed dependencies, prior state and reason. Frozen Contracts remain immutable except through the approved amendment procedure. Replanning does not retroactively grant authority to execute already prohibited work.

## 4.2 Continuous scheduling and safe progression

**FR-SCH-01 — The approved graph is the schedule.** A deterministic event-driven Scheduler computes dependency-ready Work Orders directly from the approved DAG and other authorized tickets. The owner does not create, manually approve, or restart an auxiliary execution queue. After a unit settles, the Scheduler reevaluates eligible work and progresses while work remains authorized, resources and provider capacity permit, and no safety/human gate blocks it.

**FR-SCH-02 — Exact readiness and deterministic ranking.** Eligibility checks authoritative predecessor states, approval envelope, effective Profile and frozen gates, canonical Git basis, current plan revision, repository exclusivity, environment health, quota/budget ceilings and pending uncertain effects. Priority sorts eligible items by an owner-approved stable policy with documented tie-breakers and fairness; higher priority does not override dependency or safety rules. No LLM chooses the global queue or creates a second writer.

**FR-SCH-03 — Durable claims and idempotent recovery.** Ready → claimed → active → technically accepted → terminal or waiting transitions are durable and compare-and-swap protected. Concurrent workers, repeated events, cancellation and helper/service restart cannot cause duplicate code writers or replay an uncertain effect. A completed unit cannot be redispatched as new simply because a watcher restarts.

**FR-SCH-04 — Nonblocking *provisional* technical progression.** Where the human-approved envelope explicitly permits it, a Work Unit independently verified and locally accepted by the Supervisor may satisfy local technical dependency edges before its Ticket has final human Done. Record provisional status and provenance. No such progress authorizes remote push/merge, schema migration, destructive action, deployment, external publication, spending outside the envelope or a new architecture decision. Final human Done remains separate and visible.

**FR-SCH-05 — Rejection and dependent-work invalidation.** If the human rejects or changes a provisionally used result, stop affected active descendants at safe boundaries, revoke their eligibility, record an `INVALIDATED` dependency/evidence chain and stage bounded rework or reconciliation. Never secretly delete verified history, assume an irreversible effect can be rolled back, or mark downstream work Done. Tests must prove the invalidation reaches transitive descendants and does not disturb unrelated branches.

**FR-SCH-06 — No trivial human interrupts.** Routine compilation, environment repair, tool installation, safe retries and ordinary implementation decisions stay within the Engineer's authorized capsule/Contract. On a recoverable failure, apply finite policy-directed recovery and continue eligible independent work. Only genuine owner decisions, externally ambiguous effects, exhausted budgets, requirements conflicts or out-of-scope changes generate a Human Request. Human absence does not convert requests into approval.

**FR-SCH-07 — Resource admission and honest quotas.** Scheduling is aware of configured VM and verification capacity; a provisioned but stopped VM need not consume active CPU/RAM admission. A provider quota with no trustworthy measurement is `UNKNOWN`, never fabricated. One writing Implementer per repository remains hard. Multi-project concurrency is formally qualified in P7; Phase 6 can serially schedule one project.

## 4.3 Human continuity, quality and observation

**FR-HUM-03 — Human Inbox with durable conversations.** Human Requests are revision-bound to plan/Contract/work identity and include exact legal action, evidence and consequences. The owner can ask the Planner for clarification through a new bounded read-only invocation; clarification cannot authorize. Responses are authenticated, idempotent, reject stale revisions, and resume only affected work. Email transport is not required for Gate D.

**FR-REV-01 — Future Verifier separation.** Lockstep's intended Verifier has two obligations: (1) enforce owner-approved architecture/domain and coding constraints; (2) detect test circumvention/reward hacking. The deterministic Supervisor enforces frozen-test byte integrity; the independent read-only Verifier performs semantic checks. **P6 retains current independent Challenger/Reviewer roles unless a separately approved role-transition Contract is introduced.** This requirement establishes the future interface and evidence model, not implementation authority for a new agent role.

**FR-OBS-01 — Evidence-linked command center.** Present project/plan revision, completed versus eligible versus waiting units, dependency reasons, provisionally accepted work, Human Inbox, capsule and provider status, exact Git/test evidence, resumption controls and blocking reasons. Never show final Done or publication where only technical verification happened. Work continues when the browser is closed.

**FR-KNW-09 — Bounded Scribe and proposals.** The read-only Scribe summarizes actual evidence, completed and waiting units, interventions and decisions. Structured improvement proposals are candidates for human approval, never self-installing prompts/Skills/Profiles. No invented cost figure from subscription token usage.

**FR-UX-11 — Existing checkout as project source.** The operator may select an existing authorized checkout; Lockstep derives a protected working copy/capsule basis without requiring a manually maintained duplicate folder or allowing an Implementer to mutate the original. This is a **usability follow-up**, not a hard Gate D dependency for the Caesura PRD path unless real onboarding is otherwise blocked.

# 5. Nonfunctional requirements — Phase 6 extensions

**NFR-20 — Deterministic scheduling.** Given the same authoritative state, policy revision, host resource observations and ordered input events, the Scheduler produces the same eligible ordering and claims; no model calls participate in admission.

**NFR-21 — Work continuity.** After service/helper restart, browser logout or provider-session loss, durable state reconciles exactly once without duplicate writers or acceptance; execution resumes at the next safe authorized boundary. Unknown effects remain unknown until reconciled.

**NFR-22 — Provable architectural and test integrity.** Accepted changes retain frozen-test digests, source-grounded requirements, complete read-only review scope, verification execution evidence and Supervisor-controlled Git. An Implementer cannot alter protected tests or fake the verification environment.

**NFR-23 — Minimal human attention.** Gate D measures manual Continue/queue setup, unneeded retries, human approval count, manual environment interventions and final Done separately; eligible work must advance without an operator click or an agent-manager prompt.

**NFR-24 — Bounded unattended security.** Before unattended Caesura execution, a host-enforced network boundary must protect host services beyond Lima guest-admin control; guest isolation, credential separation, image provenance and fault recovery must be qualified. A temporary listener exception is insufficient.

**NFR-25 — Observable scale and resource safety.** Track active vCPUs/memory/disk, time/cost ceilings and verification occupancy. Resource refusal is a truthful waiting reason, not a hidden denial or unbounded fallback. Multi-VM capacity targets are empirical and not invented guarantees.

# 6. Gate D — acceptance stories and actual Caesura dogfood

## 6.1 Model-free mandatory stories

| ID | Acceptance story |
|---|---|
| D-01 | PRD produces a versioned DAG with correctly typed prerequisites; an invalid cycle and contradictory requirement are rejected. |
| D-02 | Plan/authority envelope approved once; first ready Work Unit starts without a separately authorized queue. |
| D-03 | Three or more linked Work Units execute sequentially across the established Planner/RED/Implementer/verification/Reviewer/Supervisor pipeline using scripted roles and real Git/processes/PostgreSQL. |
| D-04 | Completion of a verified unit automatically makes a dependent local unit eligible without Human Done on each, **only under the owner's recorded provisional policy**. |
| D-05 | A rejected provisional ancestor invalidates all dependent descendants; unrelated units remain eligible; irreversible effects are never guessed away. |
| D-06 | A missing resource/quota, owner decision, failed test, wrong basis or uncertain effect blocks exactly the affected work, with legible reasons, no false-green evidence or duplicate dispatch. |
| D-07 | Restart midway through a claim, after evidence settlement and between dependency transitions produces no duplicate code writer, unreviewed acceptance or lost Human Request. |
| D-08 | A source Ticket and a PRD-derived Subphase both enter the same canonical engine; external intake fixtures maintain source IDs and dependency provenance. |
| D-09 | Human Inbox handles clarification, stale reply, authenticated exact decision and safe resume; a notification or agent text cannot authorize work. |
| D-10 | UI and Scribe project the true DAG, provisional/final states, evidence, resource waits and required human actions. |
| D-11 | Security tests establish no unauthorized host LAN access for unattended execution, no token/host Docker socket in guest, no test tampering or untrusted Git effect. |

## 6.2 Real-world Gate D — Caesura

**FR-GD-01.** The owner supplies Caesura's actual approved PRD and an explicit first application milestone. Do not fabricate feature requirements or claim to have frozen a PRD absent that approval. The Planner constructs a phase-ordered DAG and surfaces architecture, environment and acceptance for one meaningful approval.

**FR-GD-02.** Within the approved envelope, Caesura progresses through **at least three genuinely dependent** engineering Work Units, with meaningful code, genuine RED/GREEN tests where applicable, a running or demonstrable application increment, independent review and Supervisor commits. No parallel writes within the repository.

**FR-GD-03.** The run must show that technically accepted local work can unlock the next ready Work Unit without human Continue, separate queue authorization or an automatic final Done. Collect wall time, model sessions, usage (including caches where reported), environment interventions, retries, policy halts and human decisions.

**FR-GD-04.** The trial is separately authorized for actual provider usage and must run within an explicitly bounded resource/network envelope. Unattended operation requires a host-enforced LAN boundary and relevant crash/isolation qualification—not an expired Brigid exception. A demonstration with the owner attending may be staged first and labeled accordingly, but cannot be misreported as fully unattended.

**FR-GD-05.** Human reviews meaningful progress and decides final Done, acceptance of consequential milestones and any proposed plan changes. Gate D is accepted only by the owner after the evidence and named limitations are presented.

# 7. Ratified D6 direction and remaining implementation decisions

| Decision | Approved direction / remaining decision | When required |
|---|---|---|
| **DG-08** | Owner approves plan version and freeze semantics; no hidden Planner rewrite of accepted dependencies or Contract | Before P6.4 plan execution |
| **D6-AUTH** | Owner ratifies provisional local technical progression vs final Human Done, and limits irreversible effects | Before P6.5 scheduler dispatch |
| **D6-SOURCE** | Prefer one thin real read-only Jira/Shortcut intake adapter where configured; full writeback P9 | Before claiming live external intake support |
| **D6-SEC** | Host-enforced LAN isolation and multi-capsule/restart qualification prerequisites for *unrestricted unattended* run | Before unattended Caesura and P7 |
| **D6-GATE** | Model-free linked-work proof and separately approved real Caesura milestone are mandatory for final Gate D | Before freezing Gate D test workload |
| **DG-09–14** | Existing future GitHub, tracker mutation, Skills, Red Team, email identity decisions remain open | Their appropriate phases only |

An Implementer may prepare decision packets and model-free tests, but cannot approve these decisions itself. The owner's 13 November 2026 approval ratified the stated D6 directions; DG-08 and separately scoped implementation decisions still require their own recorded dispositions. This ratification does not retroactively change historical records.

# 8. Phases 7–12 — preserved future product requirements

| Revised phase | Primary scope | Gate |
|---|---|---|
| P7 | Independent Engineer ownership across repositories, per-Engineer auth/provider/quota context, deterministic global resource admission, two-repository negative isolation and fault test | E1 |
| P8 | GitHub branches/PRs, authorized publication, review ingestion, correction Work Orders, verified integration; keep local accepted, published, integrated and Done separate | E2 |
| P9 | Full Jira/Shortcut ticket field ownership, priority/blocker mapping, reconciliation, idempotent external writeback and external Done boundaries | E3 |
| P10 | Scoped Skills Library, prompt/profile evaluation, human-controlled install, rollback and safe sharing | F1 |
| P11 | Restrained Red Team under exact target scope; separately independent email channel with authenticated replies governed by DG-14 | F2 + communication gate |
| P12 | Full Scribe briefings, notifications, quota/fault/restart handling, packaging and owner-ratified Vacation Day Test | F3 |

**F3 is preserved:** 2–4 independent Engineers, predeclared full day, no UI or terminal rescue, no more than five substantive human email replies (including clarifications), transparent safety alerts and meaningful independently verified progress. Five or more simultaneous Engineers remains a later scaling target, not a silent change to F3.

# 9. Traceability, preservation and publication

Original v0.3's crosswalk is retained with the following prospective move: v0.3 P5 → v0.4 P6; P6→P7; P7→P8; P8→P9; P9→P10; P10→P11; P11→P12. The completed P5 is Dev Capsules / VM-1, and the post-P5 stabilization is an accepted operation baseline, not a replacement for original P5 backlog/planning scope.

Existing `FR-APP-*`, `FR-WRK-*`, `FR-EXE-*`, `FR-SEM-*`, `FR-DEL-*`, `FR-KNW-*`, `FR-UX-*`, `FR-AUX-01`, `FR-HUM-01/02`, `FR-COM-01/02`, `FR-ORG-01`, `FR-DEP-01`, `FR-F3-01`, and NFR-01–19 remain in force. This edition adds `FR-CAP-*`, `FR-AUTH-01`, `FR-OPS-*`, `FR-PLAN-*`, `FR-SCH-*`, `FR-HUM-03`, `FR-REV-01`, `FR-OBS-01`, `FR-KNW-09`, `FR-UX-11`, `FR-GD-*`, and NFR-20–25. New IDs are adopted with this edition, subject to collision verification against the complete v0.2 requirement register before canonical publication.

The release PRD governs *testable requirements*; the Bible governs product constitution; the Plan governs ordering and gates. Accepted Contracts and source evidence control historical implementation truth. Neither this document nor its PDF constitutes a repo commit, owner signature, Gate D authorization or implementation receipt.

**Historical annex:** The complete approved v0.3 PRD is incorporated without editing in the companion PDF and retains its original Oct 25 approval status. Its old phase numbers are historical; use the prospective mapping above when planning new work. The v0.2 baseline must be attached to the canonical source register when available rather than silently replaced.
