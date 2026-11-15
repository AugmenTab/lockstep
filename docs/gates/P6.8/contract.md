# Contract — P6.8 Evidence-linked summary

- Contract ID: `C-P6.8@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06.md` §13 (P6.8); `.local/plans/phase-06_update1.md` §7 (no live provider calls).
- Basis: `phase-6` after C-P6.7 qualified.
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

The Progress page (C-P6.2) gives each task one standing from the canonical rows. It says model usage is not
recorded. Nothing yet shows, in one place and with links to the evidence, what actually happened in a project:
- which work is verified, Done, invalidated or uncertain;
- what was verified and reviewed, with which outcome;
- which decisions wait for the owner;
- which interventions were needed and which were avoidable;
- what the models used.

P6.8 adds a **deterministic summary**, selected by pure rules from the records, never from an agent's words. Every
claim links to the exact evidence it rests on. There is no model Scribe in this subphase: the handoff makes one
optional, and update 1 allows no live provider calls. Every explanation in the summary is Lockstep's own fixed wording.

| # | Decision |
|---|---|
| E1 | **Categories** (pure `Lockstep.Kernel.Summary.categoryOf`): each task is exactly one of `planned` (a unit of the plan in effect, not yet ready), `eligible` (ready and not handed over), `active` (its fix running), `awaiting-person` (its fix halted for a decision), `verified` (its fix accepted by the Supervisor and still counting; local only, not Done), `done` (the person's Done), `invalidated` (its accepted fix stopped counting), `uncertain` (its fix's last role run is uncertain: neither failed nor finished), `stopped`, `canceled`, `waiting` (anything else, with its standing). |
| E2 | **Outcomes, never assumed.** A fix's verification is `passed`, `failed` or `not-run` (no verification record), and a fix not run is never `passed`. Its review is `approved`, `rejected`, `needs-person` or `not-run`, and an incomplete review is never `approved`. An uncertain run is neither a failure nor a completion. Publication is `local` for every commit: nothing is pushed or merged in Phase 6. |
| E3 | **Evidence links.** Every claim carries its evidence: the fix (transaction), the record (transaction and sequence) its verification or review outcome comes from, the accepted commit, the invalidation, the open request. Each link names a canonical row or commit that exists. A claim with no evidence says so, and is never filled with narrative. |
| E4 | **Interventions.** Each person's answer to a halt is listed with its halt code, and so is each Done or Not done. `necessary` covers decisions only a person may take (a reproduction not found, a review or finding that needs a person, exhausted attempts, an invalidation, an ambiguous basis, Done or Not done). `avoidable` covers halts from the environment or a role failing (a role failed or was uncertain, a Supervisor step failed, a verification environment missing, the checkout dirty). Any other code is `unclassified`, never guessed. |
| E5 | **Usage, as observed.** For each role run, the token counts its helper printed (the Claude JSON result's `usage`), per class: `input`, `output`, `cache-creation`, `cache-read`. Missing classes are unknown, not zero. A run with none is counted as `usage-unknown`. Totals add only known counts. There is no money: no cost is ever computed from subscription tokens. |
| E6 | **Freshness.** A summary names the plan revision (its digest) and the latest record it was made from. `summaryStale` is true once the effective revision differs, so a summary of an older revision is never shown as current. The page always makes a fresh one. |
| E7 | **No authority.** Making or showing a summary writes nothing. No text in it, and no agent text it quotes, changes a category, an outcome, or any state. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Summary` (`Category`, `Verification`, `ReviewOutcome`, `Evidence`, `FixSummary`,
  `ItemFacts`, `categoryOf`, `Intervention`, `interventionOf`, `Usage`, `addUsage`, `Summary`, `summaryStale`).
- Application: `Lockstep.Application.Summary` (`projectSummary`, `usageFromOutput`).
- Web: the Progress page's "What happened, with its evidence" part.

## 3. Mandatory tests (handoff §13) → cases

| Handoff test | Where |
|---|---|
| No-run is not success | unit (`not-run`); integration `outcomes` (a fix halted before verification) |
| Unknown effect is not failure or completion | unit (an uncertain run is `uncertain`) |
| Incomplete review is not approval | unit (`needs-person`, `not-run`); integration `outcomes` |
| Stale summary cannot misrepresent a newer revision | unit (`summaryStale`); integration `freshness` |
| Invalidated descendants remain visible | integration `invalidatedVisible` |
| Provenance links resolve to canonical evidence | integration `linksResolve` |
| Generated text cannot grant authority | integration `noAuthority` (an Implementer claiming it is Done and approved; nothing written) |
| Provider usage distinguishes token classes where available | unit (`usageFromOutput`); integration `usage` |

## 4. Verification files

`test/unit/Lockstep/Kernel/SummaryTest.hs`, `test/integration/Lockstep/SummaryTest.hs`, the runners.

## 5. Freeze record

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/SummaryTest.hs` | `102fa9dfb3ec4f36c8739fcfa8a42cf1af91973577cd421ceb0e5f4bb8513038` |
| `test/integration/Lockstep/SummaryTest.hs` | `60b4aa10808d7fd9a6c12ca15c97623e7ce341a6d11d94a17a49dee36107d9a2` |
| `test/integration/Main.hs` (shared runner; supersedes R-P6.7's digest, additive) | `67758de06a521de207d0414823b817a2c8f9435ba3af30fddf53a8521d580894` |
| `test/unit/Main.hs` (shared runner; supersedes R-P6.7's digest, additive) | `a51fca3a5a6592a7101dbc9b763e85fe7507b2d3637880404808e7f86e417192` |

Formatted and linted before the digests were taken. Lint's two hints were fixed first; one was in the integration
test, a functor-law rewrite of a pass condition.

**RED baseline against the stubs.** The stubs are `Kernel.Summary` (types; empty codes; every task `waiting`;
nothing classified, added or stale) and `Application.Summary` (no summary; no usage). Nothing else changed.
- Unit: **15 of 17 fail**. The two that pass assert what the stub's constants give: an unknown code is
  unclassified, and no output is unknown usage.
- Integration: **6 of 6 fail**, at "no summary for the project".
- Logs: `.local/evals/phase-06/p68-baseline-*.log`.

**Disclosed:** as for C-P6.6 and C-P6.7, the frozen tests were first run against the implementation in the working
tree (unit 17/17, integration 6/6, `.local/evals/phase-06/p68-pretrial-*.log`). No fixture correction was needed.
After the lint fix the integration trial was run again (6/6). The stubs were then put in place and the baseline above
run on them.

## 6. Allowed paths

New: §2/§4 files, `docs/gates/P6.8/**`. Changed: `Web/ProgressPage.hs`, `Web/App.hs`, the runners,
`docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free (scripted roles). No migration.
