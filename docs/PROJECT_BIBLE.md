# Lockstep — Project Bible (canonical repository record)

- Current constitution: **Project Bible v2.2 — Final / Ratified, 25 October 2026**
  (decision `LS-BIBLE-2.2-RATIFY-2026-10-25`), as amended by **`LS-BIBLE-2.2-ALIGN-01`**
  (approved by the human owner on 25 October 2026, approval record
  `LS-V2-DOCS-0.3-APPROVE-2026-10-25`; §2 below).
- Supersedes as current constitution: Bible v2.1 (16 October 2026, sha256 `62196658…640ff`), which
  stays the historical authority for records made under it.
- Recorded in the repository by the writing agent (Implementer) at the owner's instruction,
  2026-10-25. The agent decided nothing here.

## 1. Sources and text

| Item | Location | SHA-256 |
|---|---|---|
| Ratified v2.2 PDF (immutable source; 75 pages; not committed) | `.local/LOCKSTEP_PROJECT_BIBLE_v2.2_FINAL.pdf` | `bbaddf281b4da6af97f341ff8aba5f794df41d781aa23e67082f26e96ebb018f` |
| Full v2.2 text, verbatim machine extraction of that PDF | [`bible/PROJECT_BIBLE_v2.2.txt`](bible/PROJECT_BIBLE_v2.2.txt) | `7706762014b3d44d749e3bda351ebc05ff79ecfa53059758d3be5f2195baa815` |

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

## 3. Reading order

1. This file's §2 amendment.
2. The ratified v2.2 text, including its own reading guide: the v2.1 body pages are retained,
   nine v2.2 inserts follow their source sections, and v2.2 §3.1 replaces only original §3.1
   item 1.
3. Implementation PRD v0.3 (`docs/prd/`) and Dependency-Aware Plan v0.3 (`docs/plans/`), which
   read with PRD v0.2 for unchanged requirement text.
