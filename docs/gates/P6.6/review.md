# C-P6.6 — full check, independent review and remediation (R-P6.6)

- Reviewed: `e28bf89` (implementation) against `C-P6.6@v1` and its freeze commit `54be30a`.
- Reviewer: an independent read-only agent, 2026-11-14 (nothing built or run by it).

## Full check of `e28bf89`

`scripts/check --integration` on `e28bf89`: format, lint/static, build, unit **1023/1023**, no-live-model guard,
integration **661/661**, backup/restore — **all PASSED** (`.local/evals/phase-06/p66-full-check.log`).

## Review findings and dispositions

The review confirmed several points:
- The G4 precedence and refusal codes are right.
- The hand-over's facts are the Work Order's, as `createWorkOrderIn` and `loadBinding` resolve them, so the binding
  and digest stay the repository Profile's.
- Plain bug fixes (C-P4.1 X2/X6) are unchanged.
- Budgets cannot be configured.
- Migration 28's values match the kind codes.

| # | Finding | Disposition |
|---|---|---|
| 1 (high) | G5 c looked only at freeze → candidate. A documentation unit's frozen "test" could be a new or changed program file, which was committed at the freeze and never judged. | **Fix (R-P6.6-1):** a non-behavioural kind's candidate tests must be at test paths (`pathClassOf` gives tests), else the candidate is rejected `test-path-not-test` (a correction round). Before acceptance, everything from **basis** → candidate must be documentation, except the frozen tests at their test paths. |
| 2 | `pathClassOf` took every `.md`/`.txt` for documentation: dependency pins, instructions for model roles (`CLAUDE.md`, `AGENTS.md`, `.claude/**`), files under `src/`. | **Fix (R-P6.6-2):** `requirements*`, `constraints*` and `runtime.txt` are dependencies. Agent and assistant instruction files and `.claude/` / `.github/` are configuration. Anything under `src/` or `lib/` is source. Other documentation extensions stay documentation (the frozen C-P6.6 cases, such as `notes.txt`, keep their class). |
| 3 | A file without extension was documentation when its name only started with `readme`, `license`, … | **Fix (R-P6.6-3):** whole names only. |
| 4 | The Kernel does not tie `CandidateCharacterized` to green-only kinds; red-first depends on the engine's branch. | **Guard added** (an integration test: a feature with only green tests is corrected until exhausted). Carrying the rule in the transaction state is **not done**: the engine reads the kind from the admission at every candidate. Recorded as a limitation. |
| 5 | For green-only kinds, an existing basis test that already fails at the basis halts `green-regression-failed`, not a correction. | **Intended, now in the contract (G5 b):** a test the basis already has, failing, is a pre-existing failure for a person (C-P4), whatever the kind. |
| 6 | The hand-over can return `profile-unknown`, which G4 does not list. | **Contract text corrected:** `profile-unknown` (a named Profile neither in the catalog nor built in; proposal validation normally prevents it). |
| 7 | Anyone could register a different `lockstep-engineering` first. Choosing the engineering checks would then bind it without notice. | **Fix (R-P6.6-7):** `profile add` refuses a `lockstep-engineering` document that is not Lockstep's own (`profile-reserved`). Registration records the definition's own version. |
| 8 | The Plan page offered the engineering checks whenever a unit was not a bug fix, whether or not the project's checks covered it. | **Fix:** offered only when the plan's next unit was refused for missing checks (`kind-checks-missing` or `profile-checks-missing`). Not tested (page only). |
| 9 | The engine read the kind after invoking the role or running the baselines; a missing admission wasted them. | **Fix:** the kind is read first. |
| 10 | The floors are presence checks; no gate evidence (e.g. the refactor's human approval record) is evaluated before acceptance. This is the same as C-P4's bug checks. | **Recorded:** as for C-P4. The owner's approval of the plan revision (C-P6.4 decision row) is the refactor's human approval. Evaluating gate evidence is not part of Phase 6. |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/WorkPolicyReviewTest.hs` | `1d75818701608a52fb94ecb71f867b568d109f5e41c82a7c8d4ed9250d9e7f9a` |
| `test/integration/Lockstep/ProfileParityReviewTest.hs` | `a9b17cfbc5d7c30ff803fe58910695b2c8f9aae550b0ba73f128e16e53b53e4c` |
| `test/integration/Main.hs` (shared runner; supersedes C-P6.6 §5, additive) | `fa05de36bc094befa0c6817541966658ae10545109482d9ce540fb49b92d1035` |
| `test/unit/Main.hs` (shared runner; supersedes C-P6.6 §5, additive) | `838352a2222ece2a3e5d10bb9bc8b89dd47101f65581c6637dd6d6c9833424a8` |

Formatted and linted before the digests were taken. Baseline against `e28bf89`:
- **Unit: 5 of 6 fail** at the path rules. The documentation names that stay documentation pass.
- **Integration: 2 of 6 fail.** R-P6.6-1: the documentation unit whose frozen test is a program file is accepted.
  R-P6.6-7: the document named `lockstep-engineering` is registered.
- **Kept as guards** (they pass): the all-green feature, `profile-checks-missing` (G4 c had no test),
  `profile-too-weak` for a bug fix, and `reproduction-not-expected` for documentation.
- Logs: `.local/evals/phase-06/p66r-baseline-*.log`.

## After remediation

(filled after the trial and the full check)
