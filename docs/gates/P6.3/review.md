# C-P6.3 — full check, independent review and remediation (R-P6.3)

- Reviewed: `2177b8e` (frozen tests, migration 23, stubs) and `ad191be` (implementation), contract `C-P6.3@v1`.
- Reviewer: an independent read-only agent, 2026-11-14 (nothing built or run by it).

## Full check of `ad191be`: FAILED (2 of 617 integration cases)

`.local/evals/phase-06/p63-full-check.log` — format, lint, build, unit (950/950), guard PASSED; integration **615/617**:

1. `InboxTest` "a person's question gets one read-only Planner answer…" — the frozen literal `"human"` for a
   principal C-P4.3 stores as `"Human"`: **amendment A-P6.3-1 requested** (`amendments.md`), not applied.
2. **Regression in the implementation:** the frozen C-P4.16 `EnginePageTest` "typed text is escaped, and the section
   has no internal words…" — the new conversation text on a stopped fix said "Lockstep's Planner", and "planner" is a
   banned word in the task page's ordinary text (`EnginePageTest.hs:173`). **Fixed (R-P6.3-7):** the page now says
   "Lockstep" only; no frozen test changed.

## Review findings and dispositions

| # | Finding | Disposition |
|---|---|---|
| 1 | The Planner was not given the request's evidence (I4): only the question, choices and rule. | **Fixed (R-P6.3-1):** the context carries the request's evidence and the halt code of the fix. |
| 2 | A crash after the Planner message was posted but before the attempt was finished left it recorded `uncertain` with nothing posted — contradicting what happened. | **Fixed (R-P6.3-2):** settling an unfinished attempt first looks for its message (key `clarification-<attempt>`); if it was posted, the attempt is finished `answered` with that answer's digest. |
| 3 | Settling every unfinished attempt at the start of a pass, and the count-then-insert bound, are safe only with one worker. | **Fixed:** the whole clarification phase runs under a session lock (`ClarificationLock`); a second worker skips the phase while one holds it. (Not separately tested: concurrency of two services.) |
| 4 | The phase ignored a stop request and ran every question before any transaction could move on. | **Fixed (R-P6.3-4):** the stop is checked before each question; a stop requested before the phase runs nothing. |
| 5 | The workspace was not released on an exception. | **Fixed:** released in `finally`. |
| 6 | The task page never said that no answer came or that the limit was reached; it always offered Ask. | **Fixed (R-P6.3-6):** the page says when Lockstep could not answer (no helper, failed, cut off) and, once 3 answers were tried, says so and offers no more asking. |
| 7 | The bound counted no-helper attempts, so a deployment with no helper used up a request's questions for nothing; the words promised answers. | **Fixed (R-P6.3-5):** only attempts that ran (answered, failed, cut off) count; words say "tried". |
| 8 | Failed clarifications were never logged. | **Fixed:** the worker logs every clarification that failed or was cut off. |
| 9 | Clarification runs leave no `lockstep_invocations` record (argv, exit, output, usage). | **Recorded limitation:** the attempt row keeps its outcome, code and answer digest; per-run process evidence and usage for clarifications are NOT_RECORDED. To be joined with the engine's invocation record when the Scribe's usage accounting arrives (P6.8). |
| — | "Supervisor" appeared in ordinary text through `retryOperation` (Freeze, Accept). | **Fixed:** the two sentences say "Lockstep's commit" instead (no frozen test pins them). |
| — | "It stopped while at a step this page does not know." | **Fixed** wording. |
| — | `inboxEntries` runs per-request queries every pass. | **Recorded:** acceptable at Phase 6's single-project scale; a batched read is noted for P7. |
| — | The I2 check inside `InboxTest.inbox` compares with `choiceConsequence` itself (circular); A-P6.3-1 overstated what the other cases cover (only `questionAnswered` checks the answer's principal and evidence). | **Recorded.** The unit tests carry I2; the attribution check depends on A-P6.3-1. |
| — | Capsule mode: whether an empty workspace keeps a capsule-bridged Planner from reading the project capsule. | **Open, recorded:** live/capsule clarification is NOT_RUN; to be checked before any live use. |

## After remediation

Full check of `2d65a1f`: format, lint, build, unit 950/950, guard PASSED; integration **621/622** — the only failure is
A-P6.3-1 (pending owner authority); backup/restore NOT_RUN on this revision (it runs only after a passing
integration step). `.local/evals/phase-06/p63r-full-check.log`.

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/integration/Lockstep/InboxReviewTest.hs` | `647cb92a34cdc7d393eb600f5f92abf958541fbc6d636fbc605f792683a7f8cd` |
| `test/integration/Main.hs` (shared runner; supersedes the C-P6.3 §4 digest, additive) | `15fff5889b4f00eef9277f5fccec4244798a7b07368cd25e2c2765dc21a72c70` |

Baseline against `ad191be` (with `answerClarificationsUntil` ignoring its stop check and `clarificationContext` the
existing context): **5 of 5 fail**, each at its defect (`.local/evals/phase-06/p63r-baseline.log`).
