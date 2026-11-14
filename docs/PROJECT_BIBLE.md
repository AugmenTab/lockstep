# Lockstep — Project Bible (canonical repository record)

- Current constitution: **Project Bible v2.3 (`LS-BIBLE-2.3-01`), ratified by the human owner on 13 November
  2026** (§3 below). v2.3 is an interpretive overlay on the preserved **Project Bible v2.2 — Final / Ratified,
  25 October 2026** (decision `LS-BIBLE-2.2-RATIFY-2026-10-25`), as amended by **`LS-BIBLE-2.2-ALIGN-01`**
  (approved by the human owner on 25 October 2026, approval record `LS-V2-DOCS-0.3-APPROVE-2026-10-25`; §2
  below). v2.3 qualifies or supersedes only the clauses it names; every other v2.2 provision keeps its force.
- Paired governing editions: Implementation PRD v0.4 and Dependency-Aware Plan v0.4, approved 13 November 2026.
- Bible v2.1 (16 October 2026, sha256 `62196658…640ff`) was superseded by v2.2 and stays the historical authority
  for records made under it.
- Recorded in the repository by the writing agent (Implementer) at the owner's instruction: v2.2 and
  ALIGN-01 on 2026-10-25, v2.3 on 2026-11-13. The agent decided nothing here.

## 1. Sources and text

| Item | Location | SHA-256 |
|---|---|---|
| Ratified v2.2 PDF (immutable source; 75 pages; not committed) | `.local/LOCKSTEP_PROJECT_BIBLE_v2.2_FINAL.pdf` | `bbaddf281b4da6af97f341ff8aba5f794df41d781aa23e67082f26e96ebb018f` |
| Full v2.2 text, verbatim machine extraction of that PDF | [`bible/PROJECT_BIBLE_v2.2.txt`](bible/PROJECT_BIBLE_v2.2.txt) | `7706762014b3d44d749e3bda351ebc05ff79ecfa53059758d3be5f2195baa815` |
| Ratified v2.3 consolidated PDF (v2.3 front matter and amendment, then the unmodified 75-page v2.2 PDF as annex; not committed) | `.local/LOCKSTEP_PROJECT_BIBLE_v2.3_FINAL.pdf` | `f29fe7f3feb35fe83d3bed858e20b300e8f14a1a1d437a0a84f0bf63e9a6f6c3` |
| Ratified v2.3 amendment text, as supplied by the owner | [`bible/PROJECT_BIBLE_v2.3_AMENDMENT.md`](bible/PROJECT_BIBLE_v2.3_AMENDMENT.md) | `4a14dfee364ae0f6669d574cd3df04424ee5892d7d997b1953045c2dfd9b590d` |
| Approved Implementation PRD v0.4 PDF (not committed) | `.local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.4_APPROVED.pdf` | `70e082283842b1eb14b15ceb37f840f49cf70cd924527a747a53ac0650fe45ff` |
| Approved Implementation PRD v0.4 (`LS-V2-PRD`), text as supplied by the owner | [`prd/IMPLEMENTATION_PRD_v0.4.md`](prd/IMPLEMENTATION_PRD_v0.4.md) | `a69558b1d862b917b6bdd5ba7358cb6551df9b0669d576e2cf56ee74dc1c4522` |
| Approved Dependency-Aware Plan v0.4 (`LS-V2-DAP`), text as supplied by the owner | [`plans/DEPENDENCY_AWARE_PLAN_v0.4.md`](plans/DEPENDENCY_AWARE_PLAN_v0.4.md) | `7e47850468693cf9f8df713ac4afc9e12da2d4709eea33d6a0642d44661e5c50` |

The text file was produced by `pdftotext -layout` (Debian bookworm `poppler-utils`
22.12.0-2+deb12u3) and is committed unedited: no word was retyped or corrected. Layout artefacts
of the PDF (narrow-column pages in Parts V, VII and VIII, tables flattened to text, the two
diagrams in §§10 and 35 absent) are the PDF's own presentation, noted already for v2.1 as
SRC-OBS-02. **Where the extraction and the PDF differ, the PDF governs.**

## 2. Amendment `LS-BIBLE-2.2-ALIGN-01` (approved 25 October 2026)

Source: Implementation PRD v0.3 §2 (`docs/prd/IMPLEMENTATION_PRD_v0.3.md`), quoted exactly.
It is a narrow addendum: the ratified v2.2 PDF and its text are not changed or redated.

> **Conflict A:** v2.2 ratification guide, printed page 2, states that "Phase 3 and Gate C remain
> bounded to the existing single-Engineer ticket-to-code milestone." This preserves the old
> meaning. The owner later accepted Phase 2 engineering work, explicitly deferred the Gate B
> browser review, and directed the new Phase 3 to deliver a browser-first usable product, pushing
> ticket-to-code execution into the next phase.
>
> **Conflict B:** v2.2 §13.3 uses legacy identifiers P3.14, P4.3, and P10.2; v2.2 §39's
> Milestone C describes real bug-fix execution. A plan-only renumbering must not silently change a
> ratified constitutional reference.
>
> APPROVED narrowly bounded Bible-alignment decision, LS-BIBLE-2.2-ALIGN-01:
>
> 1. Update the introductory phase/gate guardrail to: "The Phase 2 engineering foundation may be
>    accepted while its human Gate B walkthrough remains deferred. A separately human-authorized
>    Phase 3 establishes secure UI-first local operation and human usability (new Gate C-UX). The
>    former Phase 3 single-Engineer ticket-to-code acceptance becomes Phase 4 (Gate C-EXEC),
>    without weakening its protected tests, semantic review, Git authority or recovery. The
>    Bible's statements are product requirements, not implementation evidence."
> 2. Read §39 original Milestone C as C-EXEC (Phase 4); add C-UX (Phase 3) for trusted bootstrap,
>    onboarding, project/task organization, decisions, status and human browser walkthrough. Keep
>    Milestone D plan parity and E/F objectives unchanged.
> 3. Treat the P3.14 human answer/resume reference in §13.3 as the legacy Phase 3 acceptance
>    requirement now mapped to the Phase 4 bounded execution loop. Reserve durable multi-turn
>    conversation requirements for the mapped later subphase and email for P10.2 in the revised
>    plan; retain the specific non-goal that arbitrary multi-turn email is not a prerequisite for
>    first ticket-to-code.
> 4. Do not otherwise amend §3.1, §3.2, confinement, approval authority, F3 Vacation Day criteria,
>    personal/professional segregation, remote topology or any completed receipts.
>
> The human owner approved this conforming amendment together with PRD v0.3 and the paired
> dependency plan on 25 October 2026. Apply it as a traceable, narrow Bible addendum; do not
> silently replace or redate the original ratified PDF. The amendment changes future milestone
> interpretation, not prior evidence, accepted Contracts, or existing P3.1 authority.

### 2.1 Where the amendment applies in the text

| Ratified v2.2 passage (text file) | Read as |
|---|---|
| Ratification record, "Scope and authority guardrails", first bullet (printed page 2; text lines 97–99): "Phase 3 and Gate C remain bounded to the existing single-Engineer ticket-to-code milestone. No Phase 3 execution authorization follows from this ratification." | Item 1's replacement guardrail above |
| §13.3 insert 03, "Non-goal for Gate C" (text lines 1581–1584): P3.14, P4.3, P10.2 | Item 3: P3.14 is the legacy identifier now in the Phase 4 bounded loop (plan v0.3 P4.15); P4.3 and P10.2 are the plan v0.3 identifiers |
| §39 Milestone C | Item 2: C-EXEC (Phase 4); C-UX added for Phase 3 |

## 3. Bible v2.3 (`LS-BIBLE-2.3-01`, ratified 13 November 2026)

Text: [`bible/PROJECT_BIBLE_v2.3_AMENDMENT.md`](bible/PROJECT_BIBLE_v2.3_AMENDMENT.md), committed as the owner
supplied it, unedited. It is the amendment that opens the consolidated v2.3 PDF; the two were not compared word
for word when they were recorded. The v2.2 PDF and its text (§1) are not changed or redated: in the consolidated PDF they are the
historical annex, and where they conflict with a clause v2.3 names, v2.3 governs prospectively from 13 November
2026.

What it contains, by its own sections:

| v2.3 § | Subject | Clauses |
|---|---|---|
| 1 | Lockstep models one disciplined Engineer; the human is technical lead; front-loaded judgment; deterministic control plane | B23-01 – B23-04 |
| 2 | Dev Capsules as the execution substrate; credentials outside untrusted execution; separate verification; resources; host-enforced network trust | B23-05 – B23-09 |
| 3 | Two intake modes, one work graph; the plan is the schedule; bounded continuity; provisional progress with human final Done; genuine escalation | B23-10 – B23-14 |
| 4 | The future Verifier's two duties; explicit architectural standards; convention-aware tests and complete review | B23-15 – B23-17 |
| 5 | One source of execution truth; operational autonomy; Caesura as the Gate D dogfood | B23-18 – B23-20 |
| 6 | Prospective milestone map and recorded status (A through F3) | — |
| 7 | Phase renumbering: v0.3 plan to v0.4 plan (old P5.x becomes P6.x, and so on) | — |
| 8 | Ratified policy decisions D6-AUTH, D6-SOURCE, D6-GATE, D6-SEC; what it does not authorize | — |
| 9 | Document authority and how the consolidated PDF is built | — |

Its limits, in its own words: ratification "does not, by itself, authorize Phase 6 execution, external effects,
provider spending, or host administration; it does not self-accept any gate, modify an accepted Contract, or
declare future functionality complete." The renumbering in v2.3 §7 does not change persistent Contract IDs,
recorded events, gate receipts or migration history; records made before 13 November 2026 keep their v0.3
numbering.

## 4. Reading order

1. The v2.3 amendment (§3).
2. This file's §2 amendment, `LS-BIBLE-2.2-ALIGN-01`, where v2.3 leaves it standing.
3. The ratified v2.2 text, including its own reading guide: the v2.1 body pages are retained,
   nine v2.2 inserts follow their source sections, and v2.2 §3.1 replaces only original §3.1
   item 1.
4. Implementation PRD v0.4 (`docs/prd/IMPLEMENTATION_PRD_v0.4.md`) and Dependency-Aware Plan v0.4
   (`docs/plans/DEPENDENCY_AWARE_PLAN_v0.4.md`), the paired governing editions.
5. Implementation PRD v0.3 (`docs/prd/`) and Dependency-Aware Plan v0.3 (`docs/plans/`), the historical
   sources for records made under them; they read with PRD v0.2 for unchanged requirement text.
