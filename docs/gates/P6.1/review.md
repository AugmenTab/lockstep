# C-P6.1 — independent review and remediation (R-P6.1)

- Reviewed revision: `ce2ab48` (implementation), contract `C-P6.1@v1`.
- Reviewer: an independent read-only agent (no write tools used, no build), 2026-11-14. It read the contract, the
  handoff section, every new module, migration 22, the CLI changes and the three frozen test files.
- Full check of `ce2ab48` before remediation: **PASSED** — format, lint, build, unit 923/923, integration 597/597,
  backup/restore (`.local/evals/phase-06/p61-full-check.log`).

## Findings and dispositions

| # | Finding (reviewer) | Disposition |
|---|---|---|
| 1 | A cycle closed through a person-made dependency refused the **whole** import (`dependency-cycle`), contrary to B7, untested | **Fixed (R-P6.1-1).** The Kernel now receives each stored item's *current* dependencies, with paths through tasks that are not from this source collapsed to the source items they reach; only the items that would close a cycle are refused `blocker-cycle`. The application's whole-document check stays only as an integrity assertion (it can no longer fire on valid data). |
| 2 | The Kernel used the source's old blockers for stored items, so a dependency a person removed still counted (false `blocker-cycle`) | **Fixed (R-P6.1-2)** by the same change. |
| 3 | Export → import → export was not stable: acceptance lines gained `- ` and a reference per hop; near-limit acceptance and > 500 tasks exported documents import refuses | **Fixed (R-P6.1-3):** an imported task whose acceptance is still exactly its imported criteria exports those criteria (original references); otherwise one criterion per line, a leading `- ` marker removed. An export of more than 500 tasks is refused `too-many-items` instead of producing an unimportable document. Remaining limitation: a local task with acceptance within ~55 characters per line of the 4000 limit exports a document whose copy is refused `acceptance-too-long` for that item (reported, not silent). |
| 4 | A Jira page (or a partial search) could look stale or leave dangling blockers | **Fixed (R-P6.1-4):** the adapter refuses a response with `startAt` ≠ 0 or `total` greater than the issues it holds (`jira-unreadable`). The file must be the complete search result (Operator Guide). |
| 5 | Plan §5 "dependency origin and dependency kind" is not represented in `lockstep_task_dependencies` | **Deviation, recorded.** P6.1 keeps the source's statement of each item's blockers in `lockstep_task_sources.blockers` (origin = the source) and treats task dependencies as technical edges, as C-P3.6 does. Typed edge kinds (technical / human-acceptance / external) belong to the Master Plan graph in P6.4 (DG-08 §3.2 item 4). |
| 6 | CLI syntax in B14 differed from the code (`--project`) | **Fixed** in the contract text (the code and Operator Guide were right). |
| — | B5 wording ("creates nothing") vs. B13's audit row per import | **Clarified** in the contract: a repeated import creates no task, Ticket or provenance row; each accepted import still records its one audit row. |
| — | B7: an item blocked by a refused item that was imported before is not refused | **Clarified** in the contract (its task exists; tested in the frozen unit suite). |
| — | Block then unblock leaves a task `proposed` at the same row revision, so a later import may update it | **Accepted as intended** and recorded: blocking changes neither the task's content nor its edits; an edit or "mark ready" does stop updates. |
| — | Duplication with `Tasks.hs` (`requestDigest`) | **Fixed:** `Lockstep.Application.Tasks` exports `requestDigest`; the import uses it. |
| — | No database guard against a provenance row joining a task of one project to another project's source | **Fixed:** migration 22 gains a trigger refusing it (migration 22 has not been applied to any installed database; the installed service is at schema 21). |
| — | `blockers` newline text, `criteria` JSON in `text` | **Kept**, noted: both are provenance written and read only through one function each (the criteria through the document's own Fleece schema). |
| — | Concurrency test checks only that both imports succeeded and that 3 tasks exist | Noted; the frozen test is unchanged. The serialization is by table locks taken before any read. |

## Remediation tests (frozen with this record)

`test/integration/Lockstep/BacklogReviewTest.hs` (5 cases: R-P6.1-1 ×2, R-P6.1-2, R-P6.1-3, R-P6.1-4), registered in
the shared integration runner (additive).

| File | sha256 |
|---|---|
| `test/integration/Lockstep/BacklogReviewTest.hs` | `cbe20dc5882a5d1cb756a7136a321b3a55a751e793d549cf02de04ac17c2ebb4` |
| `test/integration/Main.hs` (shared runner; supersedes the C-P6.1 §4 digest, additive registration only) | `5e55589bcda3244da0e2d91ea74d89432cd390469f37c3d626c520f425e28509` |

Baseline against `ce2ab48`: **5 of 5 fail**, each at the reviewed defect (`dependency-cycle` for the whole import
×2; a false `blocker-cycle`; `- - - It works…` after two hops; a Jira page accepted) —
`.local/evals/phase-06/p61r-baseline.log`. The C-P6.1 frozen tests are not changed.
