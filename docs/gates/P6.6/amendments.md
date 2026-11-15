# C-P6.6 — amendments and contract text corrections

No frozen test was changed. The remediation tests are added in `review.md` (R-P6.6), with the shared runners' new
digests.

## Contract text corrections (from the independent review, R-P6.6)

| Decision | Correction |
|---|---|
| G4 | One more refusal at the hand-over: `profile-unknown`. It applies when the named Profile is neither in the catalog nor built in; proposal validation normally prevents it. The id `lockstep-engineering` is reserved: `profile add` refuses a document of that id that is not Lockstep's own (`profile-reserved`), so choosing the engineering checks always binds the built-in definition (R-P6.6-7). |
| G5 b | A test the basis already has, failing there, is a pre-existing failure for a person (`green-regression-failed`, C-P4), for every kind. It is not a correction round. |
| G5 c | A non-behavioural kind's candidate tests must be at test paths, else the candidate is rejected `test-path-not-test`, a correction round. Before acceptance, every path changed from the **basis** to the candidate must be documentation or a test path, so nothing comes in through the freeze (R-P6.6-1). `pathClassOf` puts these first: dependency pins (`requirements*`, `constraints*`, `runtime.txt`), build files, instructions for model roles and assistants (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.github/`, …), tests, and anything under `src/` or `lib/`. Only then is a documentation extension, or a documentation name as the whole name, documentation (R-P6.6-2, R-P6.6-3). |
| G3 | The Plan page offers the engineering checks only when the plan's next unit was refused because the project's checks do not cover it (`kind-checks-missing`, `profile-checks-missing`). |

## Limitations recorded

- **The green-only rule's input is not tied to the kind inside the Kernel.** The engine chooses
  `CandidateCharacterized` from the admission's recorded kind at every candidate, and an integration guard shows a
  red-first kind is never accepted with only green tests. The transaction's own state does not carry the rule.
- **Floors are checked for presence, not for evidence**, as C-P4's bug checks are. The owner's approval of the plan
  revision (its C-P6.4 decision row) is the refactor's human approval.
- **`lockstep-engineering` is not in the project checks page's list of choices.** The frozen C-P3.7 test pins that
  list to `lockstep-basic`. It is offered on the Plan page and can be chosen by its id.
