# Lockstep v2 — Governing Source Register

- Register ID: LS-V2-SRC-REG
- Revision: 0.2 — governing documents adopted at Gate P0 (2026-10-16)
- Prepared: 2026-10-16, manual Phase 0 execution (no v2 Supervisor exists)
- Location: `docs/governance/` on orphan branch `v2` (DG-01b accepted). The source
  PDFs themselves stay in ignored `.local/` and are identified by digest; they are
  not committed.

This register identifies the exact documents that govern Lockstep v2, their
self-declared review status, and whether a human acceptance record exists. It
does not accept anything on the human's behalf.

## 1. Authority order

Per Bible v2.1 "Document charter" and PRD v0.2 §13:

| Rank | Authority | Answers | Change discipline |
|---|---|---|---|
| 1 | Project Bible | What Lockstep is; invariants | Explicit human-approved revision |
| 2 | Implementation PRD | Required behavior and acceptance | Versioned FR/NFR IDs |
| 3 | Dependency-aware plan | Provisional build order | Separately versioned; provisional |
| 4 | Work Unit Contracts | What one execution may change | Frozen, bounded |
| 5 | Git, tests, evidence | What actually exists/happened | Authoritative machine evidence |

## 2. Governing documents

| Doc | ID | Rev | Date | Self-declared status | Pages | File (local, gitignored) | SHA-256 |
|---|---|---|---|---|---|---|---|
| Project Bible | (none stated) | 2.1 | 2026-10-16 | "Draft for human review" | 65 | `.local/LOCKSTEP_PROJECT_BIBLE_v2.1.pdf` | `62196658858675c450f1e13e561724900f27827db7b41ea774ad16ac4ba640ff` |
| Implementation PRD | LS-V2-PRD | 0.2 | 2026-10-16 | "proposed for human review"; "Design and acceptance contract draft" | 20 | `.local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.2.pdf` | `bbd407fd57285ac6d8da6deee3995a5771c9c111a5c0b62e2df81730ebc17dfe` |
| Dependency-aware plan | LS-V2-PLAN | 0.2 | 2026-10-16 | "proposed for human review"; "PROVISIONAL ENTIRELY" | 29 | `.local/LOCKSTEP_V2_DEPENDENCY_AWARE_PLAN_v0.2.pdf` | `ae85b482d17d43e2fec106e1a857ef2f68f7d1b0c1eb7d0021ecfc64dbfe6345` |
| Phase 0 handoff | (none) | — | 2026-10-16 | Human-issued execution instruction | — | `.local/plans/phase-00.md` | `23265ae4ff42b494790b50e01960b3d5bac4c33aa21ebbe78a68a089102e5ac0` |

Verification command (re-run to confirm identity):

```sh
shasum -a 256 .local/LOCKSTEP_PROJECT_BIBLE_v2.1.pdf \
  .local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.2.pdf \
  .local/LOCKSTEP_V2_DEPENDENCY_AWARE_PLAN_v0.2.pdf \
  .local/plans/phase-00.md
```

Provenance: the human operator copied the Bible PDF into `.local/` on
2026-10-16 at the agent's request; the PRD and plan PDFs were already present.
The original Downloads copies were not read by the agent.

Internal consistency checks performed (all by reading the PDFs):

- PRD declares 57 FRs and 14 NFRs. Counted: APP 9 + WRK 12 + EXE 12 + SEM 6 +
  DEL 10 + KNW 8 = 57; NFR-01…NFR-14 = 14. **Consistent.**
- Plan §19 trace index lists all 57 FR IDs plus NFR-13/14 additions. **Consistent.**
- Plan and PRD both cite Bible v2.1 (2026-10-16) as governing. **Consistent.**
- All three cite Python reference `8b045edb4100c4a8e8fe2275f7a7b597a1e944cb`; local
  `git rev-parse HEAD` returns the same SHA. **Consistent.**
- DG-01…DG-13 appear identically (numbering, subject, gate letter) in PRD §11 and
  Plan §2.3. **Consistent.**

## 3. Human acceptance status

| Document | Acceptance record found? | Disposition |
|---|---|---|
| Bible v2.1 | **No.** Document says "Draft for human review". | **ADOPTED as governing** at Gate P0, 2026-10-16 (`docs/gates/P0/gate-report.md` §6) |
| PRD v0.2 | **No.** | **ADOPTED as governing** at Gate P0, 2026-10-16 (`docs/gates/P0/gate-report.md` §6) |
| Plan v0.2 | **No.** Plan §17 step 1 makes acceptance the first frontier action. | **ADOPTED as governing** at Gate P0, 2026-10-16 (`docs/gates/P0/gate-report.md` §6) |

The Bible distinguishes "accepted direction" (human-agreed decisions, e.g.
Haskell + Launchpad + PostgreSQL, custom CSS, one Engineer per repo) from the
document's own review status. Those accepted directions are recorded in Bible
§42 item 7 as human-owner decisions through 2026-10-14. This register treats
them as binding direction **as stated by the Bible**, while the Bible revision
itself remains un-accepted.

**Gate P0 requires the human to accept (or amend) Bible v2.1, PRD v0.2 and
Plan v0.2.** That acceptance is recorded in the gate packet, not here.

## 4. Referenced sources not inspected in Phase 0

The Bible §42 evidence register cites these; none was supplied to this phase.
They are not required by the Phase 0 handoff and are not treated as authority:

| Source | Status |
|---|---|
| `LOCKSTEP_PROJECT_BIBLE_v1.0.md/.pdf` | Not in working tree (a v1.0/v2.0 PDF exists outside the working directory; not read) |
| `Lockstep_PRD_v0.1.pdf` | Not located in working tree |
| `lockstep-implementation-plan.md` (historical Python plan) | Not located in working tree root; historical plans exist under `.local-archive/plans/` |
| `ai-cost-mitigation.pdf` | Not located |
| `artificer-main.zip` | Not located; PRD §1.2 says it is not proof of Launchpad compatibility |

## 5. Proposed changes and observed issues (for human disposition)

These are observations, not edits. None changes a requirement.

| ID | Observation | Proposed handling |
|---|---|---|
| SRC-OBS-01 | Bible §43 names an authoritative editable Markdown Bible (`docs/PROJECT_BIBLE.md`); only the PDF exists. | Human decides whether to commit a Markdown source in P0.3's chosen repo, or record the PDF digest as the authority until then. |
| SRC-OBS-02 | Bible PDF pages 15–46 render Parts V, VIII, and parts of VII as a one-column narrow table (Markdown headings leaked as `# Part V —`, a pipe-table rendered as literal `| Screen |` text). Content is legible but presentation is defective. | Regenerate the PDF from the Markdown source; no content change implied. |
| SRC-OBS-03 | PRD FR-APP-03 requires "ordered DB migrations"; the audited Launchpad uses Orville **auto-migration** at startup (see LAUNCHPAD_AUDIT §6). Not a document conflict, but DG-02 must resolve it. | Carry into DG-02. |
| SRC-OBS-04 | Plan §1.5 lists suggested `docs/` destinations "not assumptions about the unavailable Launchpad checkout". Launchpad is now available; destinations still depend on DG-01b. | Resolve in P0.3/P0.4. |

No unresolved disagreement between the three governing documents was found.
