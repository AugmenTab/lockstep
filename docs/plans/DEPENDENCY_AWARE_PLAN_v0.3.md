# Lockstep v2 — Dependency-Aware Implementation Plan v0.3 (canonical repository record)

- Document ID: LS-V2-DAP, revision 0.3, 25 October 2026.
- Status: **APPROVED BY HUMAN OWNER**, 25 October 2026, approval record
  `LS-V2-DOCS-0.3-APPROVE-2026-10-25`; companion to Implementation PRD v0.3.
- Highest authority: Project Bible v2.2 (ratified), as amended by `LS-BIBLE-2.2-ALIGN-01`.
- Revises Plan v0.2 (sha256 `ae85b482…6345`). Historical Contract IDs and accepted Phase 0–2
  records are not renamed (v0.3 §9).
- Recorded in the repository by the writing agent (Implementer) at the owner's instruction,
  2026-10-25.

| Item | Location | SHA-256 |
|---|---|---|
| Approved PDF (immutable source; 24 pages; not committed) | `.local/LOCKSTEP_V2_DEPENDENCY_AWARE_PLAN_v0.3_APPROVED.pdf` | `d017a29dc7d7ab55ca0110227b48b2ef12ec742dce50790fd0c34cad74b10b42` |
| Full text, verbatim machine extraction | [`DEPENDENCY_AWARE_PLAN_v0.3.txt`](DEPENDENCY_AWARE_PLAN_v0.3.txt) | `e73f1661a613fc7cc7574eb68085b529d4b9e351e586e1a3ce929859abbd60d2` |
| Predecessor v0.2 PDF (historical; not committed) | `.local/LOCKSTEP_V2_DEPENDENCY_AWARE_PLAN_v0.2.pdf` | `ae85b482d17d43e2fec106e1a857ef2f68f7d1b0c1eb7d0021ecfc64dbfe6345` |

The text file is `pdftotext -layout` output (poppler-utils 22.12.0-2+deb12u3), committed unedited;
its tables are flattened by the extraction. Where it and the PDF differ, the PDF governs.

## Crosswalk (v0.3 §9, restated as an index; the text governs)

| v0.2 | v0.3 |
|---|---|
| P0, P1 / Gate A; P2.1–P2.9 / Gate B | unchanged |
| — | **P3.1–P3.11 / C-UX** (UI-first launch and operator experience) |
| original P3.1–P3.2 | P4.1–P4.2 |
| — (Bible v2.2 conversation core) | P4.3 |
| original P3.3–P3.16 | P4.4–P4.17 / **C-EXEC** |
| original P4.1–P4.10 | P5.1–P5.10 / D |
| original P5.1–P5.5 | P6.1–P6.5 / E1 |
| original P6.1–P6.9 | P7.1–P7.9 / E2 |
| original P7.1–P7.5 | P8.1–P8.5 / E3 |
| original P8.1–P8.5 | P9.1–P9.5 / F1 |
| original P9.1–P9.4 | P10.1, P10.3–P10.5 / F2; email at P10.2 |
| original P10.1–P10.6 | P11.1–P11.6 / F3 |

Gate identifiers: the v0.2 Gate C criteria C1/C2/C3 keep their meaning and map to C-EXEC; the
Phase 3 scenarios are UX-C1 … UX-C9 (v0.3 §2). The Phase 3 handoff's "C1–C9" are those UX-C
scenarios.
