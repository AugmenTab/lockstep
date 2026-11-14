# C-P6.2 — independent review and remediation (R-P6.2)

- Reviewed: `ff2d479` (frozen tests) and `0039526` (implementation), contract `C-P6.2@v1`.
- Reviewer: an independent read-only agent, 2026-11-14 (nothing built or run by it).
- Full check of `0039526`: **PASSED** — format, lint, build, unit 941/941, integration 605/605, backup/restore
  (`.local/evals/phase-06/p62-full-check.log`).

## Findings and dispositions

| # | Finding | Disposition |
|---|---|---|
| D1 | **Engine gap shown as a contradiction.** Marking a fix fixed changes only the fix (`Engine.decideCompletion`), never the task's Ticket, so a task whose fix is Done stays open and every task depending on it shows "Waiting for: X" next to X shown "Done". | **Page fixed (R-P6.2-1):** a waiting task now says, for each task it waits on whose fix is Done or committed, why it still waits ("its fix is Done, but Lockstep does not yet close the task itself, so this one still waits"). **The engine gap is carried to P6.7** (local technical progression and Human Done must satisfy dependencies through the governed state model, D6-AUTH) — it is the core of D-04 and must not be patched ad hoc in P6.2. |
| D2 | **A canceled task hides a live or halted fix.** `decideTask CancelTask` accepts a task whose fix is running; C1 puts canceled first, so the row says "Canceled." and a halted fix leaves *Waiting for you*. | **Not changed; decision requested.** The precedence is the contract's and is pinned by a frozen test; the underlying behaviour (cancelling a task mid-fix) predates Phase 6 (C-P3.6/C-P4.1). Options for the owner/Planner: (a) refuse cancel while a fix is running or halted; (b) show the fix's state before canceled; (c) both. Recommended: (a) in P6.5/P6.7, with the scheduler's safe-boundary stop. Recorded in the retro as open. |
| D3 | Halt and stop **codes** reached the person ("(verify-failed)"), against C5/FR-UX-06; wording differed from the task page. | **Fixed (R-P6.2-3):** the page uses the task page's own `haltWords`/`stoppedWords`. |
| D4 | C6 "never left out": a Ticket that does not replay aborts the whole read (as every page does); an unparseable hand-over would show "queued". | **Corrected:** an integrity failure is an error page, never a partial list (docstring and this record); the hand-overs are now read as typed rows (`Persistence.Execution.projectAdmissions`), so there is no text id to fail to parse. |
| D5 | N+1 reads (~3 round trips per task, separate connections, no single snapshot). | **Fixed:** the page reads hand-overs and fixes for all of the project's tasks in one database transaction. |
| D6 | The unit page test's "next to hand over" assertion is weak (the title appears elsewhere); the Kernel "only one human-done" case counts its own list; the stale-browser case POSTs to the shell address; no 503 test; the browser corrupts the session rather than revoking it. | **Recorded.** The frozen tests stay as they are; the integration test checks "next" exactly within its sentence; the read-only property rests on the page having no form and no POST route. A real revocation and a 503 page belong in P6.11's browser qualification. |
| — | Plan items not on this page: effective Profile and authority envelope, frozen-test/verification/review evidence, invalidated work. | Recorded: evidence is one link away (each row → the task page, which shows checks and review); authority envelopes and invalidation do not exist until P6.4/P6.7 and will be added to this page then. |
| — | Suggestions: list accepted fixes awaiting Done under *Waiting for you*; say hand-over is refused when the project is not enabled; pass `ProjectId` typed. | The first two are adopted in the remediation (an accepted fix is listed as waiting for your Done; "Next to hand over" says when Lockstep may not work in the project yet). The third is kept as is (the existing application APIs take text). |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Web/ProgressReviewTest.hs` | `e5a52fa475b0297b2e1a6a456cb7cbe726f7e04f5f1402e1c29bb440bf9c2f4e` |
| `test/unit/Main.hs` (shared runner; supersedes the C-P6.2 §4 digest, additive) | `2ac3dc87790a84786afb80aad5436c5822bb1b6b9fd19a1d663e7f3a7f11fb5c` |

Baseline against `0039526` plus a stub `explainWaiting = const id`: **2 of 3 fail** (the explanation; the codes on the
page). The third ("only a waiting standing is explained") passes against the identity stub by construction; it is a
guard, not evidence. Log `.local/evals/phase-06/p62r-baseline.log`.
