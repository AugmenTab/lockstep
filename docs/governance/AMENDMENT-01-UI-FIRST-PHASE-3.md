# Governing amendment 01 — UI-first Phase 3 ("The Usable Product Foundation")

- Status: **IN FORCE** by the human owner's Phase 3 handoff, 2026-10-25
  (`.local/plans/phase-03.md`, sha256 `d6dafdf2b985b55895007504ecb9b49529bee07dc08c4cd948cdbfc1a513d0c8`).
  Recorded by the writing agent (Implementer) at the owner's instruction (handoff §9). The
  agent decides nothing here.
- Amends: Plan v0.2 (`ae85b482…6345`), the build order of its Phase 3 and later phases. It does
  not amend Bible v2.1 (`62196658…640ff`) or PRD v0.2 (`bbd407fd…17dfe`) requirement text.
- Not ratified by this amendment: **the Project Bible v2.2 corrected draft.** It is reference
  material only until the owner ratifies it separately (handoff §0).

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

## 3. Old-to-new milestone mapping

| Before this amendment (Plan v0.2) | After |
|---|---|
| Gate B (end of Phase 2) | Not passed as a whole; machine qualification results kept; its browser walkthrough moves to Gate C (C8) |
| Phase 3 (engineering execution: the first real engineering Work Unit) | Becomes **the phase after the revised Gate C**, with its original safety requirements intact (handoff §9) |
| Phase 4 and later | Not addressed by the handoff: content and relative order unchanged; any renumbering is the owner's or the Planner's to settle |
| Gate C (as defined in Plan v0.2) | The handoff names the new gate "revised Gate C". How the original Gate C criteria attach to the rescheduled engineering-execution phase is to be confirmed when the plan is read (§4) |

The item-by-item mapping of the original Phase 3 sub-phases, and the check that none of their
requirements is lost (handoff §9 items 3 and 5), are in §4.

## 4. Traceability and requirement preservation

**Pending: the Plan and PRD PDFs could not be read in this session** (the PDF reader needs
`poppler`, which is not installed on this Mac; recorded in `.local/retros/retro-03.md`). Until
they are read, this section makes no claim about which FR/NFR or which original Phase 3 item maps
where. The decision gates that the register ties to the original Phase 3 stay as recorded and
unchanged: DG-06 (P3.3–P3.6 → P3.7) and DG-07 (P3.4–P3.5 → P3.6) now refer to the rescheduled
engineering-execution phase, not to the revised P3.x numbers above.
