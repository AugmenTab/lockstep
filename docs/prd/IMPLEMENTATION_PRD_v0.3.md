# Lockstep v2 — Implementation PRD v0.3 (canonical repository record)

- Document ID: LS-V2-PRD, revision 0.3, 25 October 2026.
- Status: **APPROVED BY HUMAN OWNER**, 25 October 2026, approval record
  `LS-V2-DOCS-0.3-APPROVE-2026-10-25` (together with Plan v0.3 and `LS-BIBLE-2.2-ALIGN-01`).
- Product authority: Project Bible v2.2 (ratified), as amended by `LS-BIBLE-2.2-ALIGN-01`
  (`docs/PROJECT_BIBLE.md` §2).
- Revises v0.2 (sha256 `bbd407fd…17dfe`). v0.2's requirement text stays in force by incorporation
  wherever v0.3 does not amend it (v0.3 §1, §7); every original FR/NFR identifier is kept.
- Recorded in the repository by the writing agent (Implementer) at the owner's instruction,
  2026-10-25.

| Item | Location | SHA-256 |
|---|---|---|
| Approved PDF (immutable source; 15 pages; not committed) | `.local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.3_APPROVED.pdf` | `519348e131eea2077ac50f8bb1e4157f5b370a9f48c850388261961a6f175bfd` |
| Full text, verbatim machine extraction | [`IMPLEMENTATION_PRD_v0.3.txt`](IMPLEMENTATION_PRD_v0.3.txt) | `c86da55b7a8536dec5f7635c98ee671a20ce2d7003059ac1cee04a36f8f15660` |
| Predecessor v0.2 PDF (historical; not committed) | `.local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.2.pdf` | `bbd407fd57285ac6d8da6deee3995a5771c9c111a5c0b62e2df81730ebc17dfe` |

The text file is `pdftotext -layout` output (poppler-utils 22.12.0-2+deb12u3), committed unedited;
its §4 table is flattened by the extraction. Where it and the PDF differ, the PDF governs.

## Identifiers introduced by v0.3 (index only; the text governs)

| Section | Identifiers |
|---|---|
| §2 | `LS-BIBLE-2.2-ALIGN-01` |
| §3 | FR-UX-01 … FR-UX-10; NFR-15 … NFR-18 |
| §4 | FR-AUX-01, NFR-19, FR-HUM-01, FR-HUM-02, FR-COM-01, FR-COM-02, DG-14, FR-ORG-01, FR-DEP-01, FR-F3-01 |
| §5 | Gates A (historical), B (engineering accepted), **C-UX** (Phase 3; scenarios UX-C1 … UX-C9), **C-EXEC** (Phase 4), D, E1–E3, F1–F3 |
| §8 | DG-15 (P3.1 bootstrap, = DR-P3.1 owner decision), DG-16 (Phase 3 browser-managed effects), DG-17 (Phase 4 live coding) |

Phase 3 traces (v0.3 §3): P3.1 → FR-UX-01, FR-UX-02, NFR-16; P3.2–P3.3 → FR-UX-02, FR-UX-03,
NFR-17; P3.4 → FR-UX-04; P3.5 → FR-UX-05; P3.6 → FR-UX-06; P3.7 → FR-UX-07; P3.8 → FR-UX-08,
FR-HUM-02; P3.9 → FR-UX-09; P3.10–P3.11 → FR-UX-10, NFR-15, NFR-18.
