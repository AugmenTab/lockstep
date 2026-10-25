# Governing amendment 01 — UI-first Phase 3 ("The Usable Product Foundation")

- Status: **IN FORCE** by the human owner's Phase 3 handoff, 2026-10-25
  (`.local/plans/phase-03.md`, sha256 `d6dafdf2b985b55895007504ecb9b49529bee07dc08c4cd948cdbfc1a513d0c8`).
  Recorded by the writing agent (Implementer) at the owner's instruction (handoff §9). The
  agent decides nothing here.
- Amends: Plan v0.2 (`ae85b482…6345`), the build order of its Phase 3 and later phases. It does
  not amend Bible v2.1 (`62196658…640ff`) or PRD v0.2 (`bbd407fd…17dfe`) requirement text.
- Not ratified by this amendment: **the Project Bible v2.2 corrected draft.** It is reference
  material only until the owner ratifies it separately (handoff §0).
- **Update 2026-10-25:** the owner later ratified Bible v2.2 and approved PRD v0.3, Plan v0.3 and
  LS-BIBLE-2.2-ALIGN-01 (`docs/PROJECT_BIBLE.md`). Those now govern; this amendment remains the
  record of the UI-first direction as given in the handoff.

## 1. The direction

1. **Lockstep must be usable by entirely nontechnical people** (handoff §2): developers,
   salespeople, marketers, students, artists and hobbyists. They work with projects, goals,
   tasks, priorities and decisions; Git, Docker, PostgreSQL, migrations, agent roles, Profiles,
   Work Orders, Work Units, environment variables, ports and file configuration stay internal
   where correctness needs them.
2. **One command, then the browser.** The user runs `lockstep`; the browser opens the local
   control pane; installation, configuration, project organization, task management,
   monitoring and supported decisions happen in the UI. The CLI stays for advanced use,
   scripting, tests and debugging. A normal supported task never needs a command copied out
   of the browser.
3. **The interface translates intentions into governed operations.** It uses the same typed
   domain operations as the CLI, with no duplicate policy engine in HTTP handlers, no process
   execution from form fields and no UI state that contradicts durable state (handoff §4.2).
4. **Honest state.** No fabricated completion percentages, model usage, cost, ETA or
   verification results; unavailable future capabilities are labelled unavailable (handoff
   §6, P3.8).

This phase builds accessible project and task management over the engineering foundation. It
does **not** authorize general-purpose non-code agent execution (handoff §2), nor anything in
handoff §8.

## 2. Revised Phase 3 and its gate

| Sub-phase | Subject | Dependencies (handoff §5) |
|---|---|---|
| P3.1 | Trusted launcher and bootstrap | accepted Phase 2; concrete bootstrap security design |
| P3.2 | System status and lifecycle | P3.1 |
| P3.3 | Guided installation, upgrades and recovery | P3.2 |
| P3.4 | Permanent application shell | P3.2; readiness hand-off |
| P3.5 | Guided project onboarding | P3.4; P2.1 identity and repository ownership |
| P3.6 | Tasks and work organization | P3.5; Ticket/Work Order operations |
| P3.7 | Project settings, Profiles and scheduling | P3.5–P3.6; P2.3–P2.4 |
| P3.8 | Human decisions and approvals | P3.4, P3.6–P3.7 |
| P3.9 | Activity, evidence and recovery visibility | P3.6–P3.8; P2.8 ledger |
| P3.10 | UX and accessibility hardening | P3.1–P3.9 |
| P3.11 | Gate C qualification | P3.1–P3.10 |

**Revised Gate C — Usability and Operator Readiness**, scenarios C1–C9 (handoff P3.11). C8 is
the Gate B human browser walkthrough, deferred on 2026-10-25 (`DECISION_REGISTER.md`). The
Implementer may report the Gate C package ready; only the owner accepts Gate C.

**Superseding names (2026-10-25, PRD/Plan v0.3):** this gate is **Gate C-UX** and its scenarios
are **UX-C1 … UX-C9** (the handoff's C1–C9, same order). The old Gate C criteria C1/C2/C3 keep
their meaning under **Gate C-EXEC** (Phase 4).

## 3. Old-to-new milestone mapping

Settled by the owner-approved Plan v0.3 §9 crosswalk and PRD v0.3 §7
(`docs/plans/DEPENDENCY_AWARE_PLAN_v0.3.md`, `docs/prd/IMPLEMENTATION_PRD_v0.3.md`):

| Before (Plan v0.2) | After (Plan v0.3) |
|---|---|
| Gate B (end of Phase 2) | Engineering accepted; machine qualification kept; browser walkthrough is UX-C8 |
| — | P3.1–P3.11, Gate C-UX |
| Phase 3 (P3.1–P3.16), Gate C | Phase 4 (P4.1–P4.2 = old P3.1–P3.2; new P4.3 conversation core; P4.4–P4.17 = old P3.3–P3.16), Gate C-EXEC |
| Phases 4–10 | Phases 5–11, content kept (email inserted at P10.2) |

## 4. Traceability and requirement preservation

Done by the owner-approved documents, not by this amendment: PRD v0.3 §1 keeps all 57 FRs and 14
NFRs with their identifiers and v0.2 text by incorporation, and §7 maps every original family to
its new milestone ("milestone moves, not deprecations"); the original Phase 3 requirements
(FR-WRK-06, FR-EXE-03–09, FR-SEM-01–04, FR-DEL-01) go to Phase 4 / C-EXEC intact. DG-06 and DG-07
apply to Phase 4 (PRD v0.3 §8). An earlier draft of this section said the plan could not be
read; Plan/PRD v0.2 were later read, and the owner then supplied v0.3, which governs.
