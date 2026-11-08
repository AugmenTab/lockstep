# Contract — P3.7 How work is checked, and what can start

- Contract ID: `C-P3.7@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.7 ("safe defaults, clear choices, and an Advanced section showing
  exact Profile identities, versions, digests and gates"; "priority and eligibility"; "a
  high-priority blocked task must explain its blocker"; "No UI option may silently weaken
  universal Profile requirements"); PRD v0.3 FR-UX-07; Plan v0.3 §4 P3.7 ("gate checklist and
  scheduler reason view"; verification "strengthening and refusal tests; frozen profile digest;
  blocked ≠ active"; Plan §2.1: lean, reuse Phase 2 operations); C-P2.3 (Profiles, unchanged
  rules); C-P2.4 (the scheduler, unchanged); C-P3.5 (projects); C-P3.6 (tasks).
- Writer: the single writing agent (Implementer, manual).
- Scope: a per-project page for choosing which checks apply, the exact effective Profile under
  technical details, and a read-only view of the work waiting to start with the reasons it can or
  cannot. Decisions (P3.8), activity (P3.9) and any execution (Phase 4) are **not** here. No
  Profile rule, scheduler rule or migration changes.

## 1. What P3.7 delivers

1. **How work is checked, per project.** A project with a folder has a page that lists the rules
   that always apply (the nine C-P2.3 universal invariants, in plain words, "No choice on this page
   can turn them off"), the extra checks currently chosen as a checklist (when, what is needed, who
   checks it, whose approval, whether a person may waive it, which work it applies to), and a choice
   among the available sets of checks.
2. **A safe default.** When nothing is chosen, work in the project cannot start (the C-P2.4
   `profile-default-unset` reason) and the page says so. The recommended first choice is built in:
   **Always-on rules only** (`lockstep-basic` version 1, no extra checks), registered through the
   C-P2.3 rules the first time someone chooses it.
3. **No silent weakening.** A choice can only be a registered set of checks, which C-P2.3 has
   already proved cannot waive a universal rule. A change that would remove or change any check
   now in force, or allow documents-only work to skip frozen tests where it could not before, is
   refused until the person ticks a confirmation, and the refusal names what would be lost. Every
   attempt that reaches a project with a folder leaves a C-P2.3 decision row. A stale page cannot
   overwrite a newer choice.
4. **Exact identity under technical details.** The chosen set's id, version and digest, and for
   each kind of work the effective Profile digest, its sources (level, id, version, digest) and the
   checks that apply.
5. **What can start, and why not.** The project page and its checks page show the work waiting to
   start in this project: the work that can start in its order in line, and each piece that cannot
   start yet with its reasons in plain words. Priority is shown next to it, separately: a
   high-priority piece that cannot start is never shown as able to start. This is a read-only
   preview of the C-P2.4 decision: nothing is marked, claimed, recorded or run.

## 2. Decisions

| # | Decision |
|---|---|
| L1 | **Vocabulary** (pure, new `Lockstep.Kernel.Policy`): `invariantWords` for each of the nine invariants; `checkRow :: Gate -> CheckRow` (when, needs, checked by, approval, waivable, applies to) from words for every stage, artifact kind, verifier, approval, work kind and path class (class tags shown as written); `ineligibilityWords` for every C-P2.4 reason; `checksRefusalWords` for every L5 code. None of these words contains *Profile*, *gate*, *invariant*, *Work Order*, *Ticket*, *Engineer*, *scheduler* or *digest*. |
| L2 | **Losses** (pure): `checksLost current chosen` lists `LostCheck id` for every check of the current set that the chosen set does not contain unchanged (removed, or changed in any way, even if stricter: the comparison is conservative), and `LostDocsOnlyRule` when the current set forbids documents-only work without frozen tests and the chosen one allows it (an absent setting reads as the baseline's *allowed*). No current set means no losses. `lossWords` names each. |
| L3 | **Reading** (`Lockstep.Application.ProjectChecks.projectChecks`): the project; whether its checks can be set (it has a folder: an Engineer that owns a repository); the current choice (the repository default, at its latest version, digest-checked); the choices (the built-in **Always-on rules only** first while no profile `lockstep-basic` is registered, then every registered profile at its latest version, by id); for each of the seven kinds of work, in the kind order, the effective Profile resolved exactly as C-P2.5 `createWorkOrder` would (no classes, no path classes, behaviour-changing) or the refusal code; and the queue (L6). A stored document whose digest does not reproduce is shown as unusable, never used. |
| L4 | **Choosing** (`chooseChecks project expected choice confirmed`), one transaction under the C-P2.3 profile lock, in this order: unknown project `unknown-project`; no folder `project-has-no-folder` (both record nothing); the current choice (its id, or `none`) differs from `expected` → `checks-changed`; the choice is `lockstep-basic` and no such profile exists → the built-in document is registered as version 1 (a `profile-add` decision row, accepted); the choice is not registered → `profile-unknown`; its stored document fails its digest → `profile-integrity`; the choice is the current one → **unchanged** (a decision row `unchanged`, no new default row); losses (L2) and not confirmed → `fewer-checks-unconfirmed`; else a new repository default row and a `repository-set-profile` decision row `accepted`. Refusals from `checks-changed` on leave a `refused` decision row with the code and change nothing else. |
| L5 | **Refusal codes**: `unknown-project`, `project-has-no-folder`, `checks-changed`, `profile-unknown`, `profile-integrity`, `fewer-checks-unconfirmed`. |
| L6 | **Queue preview** (`Lockstep.Application.Ledger.previewSchedule`): the C-P2.5 `scheduleOnce` load and `assemble` in a read-only snapshot, then `scheduleOrders`, with **no** lock, Scheduler command, claim or decision row. The project's entries are the queued orders of its repository, each with its Ticket title, priority and standing: **first in line** / **number N in line** (its place among the project's orders that can start, in the C-P2.4 order) or **cannot start yet** with every C-P2.4 reason. Eligible entries come first in line order, then the others by priority (highest first) and id. |
| L7 | **Pages.** `/app/projects/<id>/checks` (fragment `/app/fragments/project-checks/<id>`): heading "How work is checked", the always-on rules, the current checklist, the choice form (`#checks-form`, radios `name=choice` with ids `choice-<profile id>`, hidden `expected`, checkbox `#confirm-fewer` `name=confirm_fewer value=yes`, button `#save-checks` "Save"), "Work waiting to start", and *Technical details* (L3 identity and digests, each queued order's id and reason codes). A project without a folder gets the explanation and no form. The form posts to `/app/api/projects/<id>/checks` (session header, Origin, up to 16 KiB) and answers `200` with the checks page (`X-Lockstep-Path`) and "Saved." or the refusal in words. The project page gains a "How work is checked" section: one line naming the current choice (or that none is chosen) and the link `#project-checks`, then "Work waiting to start" when there is any. The Settings section links each project's checks page. Ordinary text outside *Technical details* has none of L1's internal words. |
| L8 | **No execution.** No P3.7 code path calls `createWorkOrder`, `scheduleOnce`, the executor or the reconciler; the page says "Lockstep does not start work by itself yet". |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/PolicyTest.hs` | unit | words for all nine invariants, every stage, artifact, verifier, approval, kind, path class and ineligibility reason, and every L5 code: non-empty, and without L1's internal words; a checklist row of a known gate; "applies to" for any and for restricted gates; `checksLost` for no current set, identical, added, removed, changed-but-stricter and documents-only cases; the built-in document is valid C-P2.3 `lockstep-basic` version 1 with no gates |
| `test/integration/Lockstep/ProjectChecksTest.hs` | integration: real PostgreSQL and Git, in-process | a project without a folder cannot be set and records nothing; the built-in default chosen and registered with its decision rows; unchanged; stale `expected`; unknown; a stricter profile chosen without confirmation; a weaker one refused without and accepted with confirmation, rows each time; the effective digest per kind equals C-P2.3 `resolveForEngineer`; a tampered stored document is unusable and refused; the queue of a task's work orders: a high-priority order waiting for another is *cannot start yet* with its reason and the lower-priority one is first in line, and the preview wrote nothing |
| `test/integration/Lockstep/ProjectChecksPageTest.hs` | integration: real service | the project page's section and link; the checks page's always-on rules, choices and form; no form without a folder; session and Origin required; choose, saved, the address; stale and fewer-checks answers in words; the queue shows a blocked high-priority piece as unable to start, with its reason; escaping; no internal words outside *Technical details*; 404s and the 16 KiB limit |
| `test/integration/Lockstep/ProjectChecksBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen), real service | sign in → a project in a new folder → its page → How work is checked → Always-on rules only → Save → "Saved." → reload: the choice is kept; keyboard only for the form |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| Frozen files (P3.7 and earlier) | digests unchanged | §4, earlier contracts' §4 |
| `scripts/check --integration` | format, lint, build, unit (785), no-live-model guard PASSED; integration 357 of 359 PASSED, the 2 failures being the known C-P3.4 `HandoverTest.hs` defect | `check-integration.log` |
| C-P3.7 groups | unit 12 of 12; in-process 8 of 8 (the preview wrote nothing: no event, no schedule decision, both orders still pending); pages 7 of 7; the real-browser journey (a project in a new folder → How work is checked → Always-on rules only → Save by keyboard → kept after a real reload) PASSED | `check-integration.log` |
| Linux clean clone of `3aa99b6` | format, lint, build, unit PASSED; integration 357 of 359. The kept tail shows every C-P3.7 case passing (the real-browser journey included); the 2 failures are outside it and match the known `HandoverTest.hs` cases in count | `linux-clone.log` |

Three implementation runs:

1. One new case failed, in the implementation and not the test. The queue said "Can start: first
   in line." where the frozen page test expects "First in line". The wording is now "First in
   line: it can start." / "Number N in line: it can start.".
2. A Phase 1 browser case (`BrowserFormTest`, untouched since C-P1.x) timed out in its driver at
   120 s; every C-P3.7 case passed. The run is kept as `check-integration-run2-browser-timeout.log`.
3. A third run with no code change: everything passed except the known 2.

Implementation notes (decisions within the design, recorded here):

- `scheduleOnce`'s two local helpers became top-level functions (`repositoryDefaultRow`,
  `orderExtras`) so `previewSchedule` can share them; their bodies are unchanged.
- `Lockstep.Kernel.Profile` gains exports only: `gateArtifacts`, `gateVerifiers`, `definitionAllows`
  (already defined) and `gateScopes` (new, the names of a gate's kinds, classes and path classes).
- When the current set's stored document fails its digest, a change away from it always needs the
  confirmation (it cannot be compared).
- The Settings section lists each project's checks page.

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the choosing and reading operations and
the pages were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/PolicyTest.hs` | `788bd322e7dff2fa2b3091d13b8785f583d2a6141d1e186ce31f61fd83784fc5` |
| `test/integration/Lockstep/ProjectChecksTest.hs` | `17f758d02870da047262534b26a00ee3faa6e33f9f9592c3c52a9fafd76ceb34` |
| `test/integration/Lockstep/ProjectChecksPageTest.hs` | `7cba4239a1defea6907f36bd99787a4a4f14e71829b90192e8b4bed4f479919d` |
| `test/integration/Lockstep/ProjectChecksBrowserTest.hs` | `7d8eeb5d21fca80dec90efe55c044be58cff67e89a7fba69775f0a2dfc040254` |
| `test/unit/Main.hs` (runner, additive) | `44fd4d988b3a70e78fbcb8b6aa1c080f8ff174a3ec04235a46d05c4330d4f420` |
| `test/integration/Main.hs` (runner, additive) | `9e5919d6efbb8f43de14b3f65e45644122901bfb5e3eb877e764f945aeb6c536` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- The pure vocabulary (`Lockstep.Kernel.Policy`) was written together with its unit test and
  passed 12 of 12 at the first run (`prefreeze-unit.log`); it was **not** run against a stub
  first. The reason is the P3.6 one: `scripts/check` stops at the first failed step, so a failing
  unit step would have hidden the integration baseline.
- `Lockstep.Application.Ledger.previewSchedule` (L6) was implemented before the freeze (a
  read-only reuse of `scheduleOnce`'s load and assembly; `scheduleOnce` itself only had its two
  local helpers lifted to top level, unchanged).
- `scripts/check --integration` against stubbed `projectChecks`/`chooseChecks` and unchanged pages
  (`prefreeze-integration-baseline.log`): format, lint, build, unit (785) and guard pass; 18 of
  359 integration cases fail: the 2 known `HandoverTest.hs` cases and all 16 new ones. Each new
  failure was read for its reason: the stubs ("the project is gone", `Left "not-implemented"`),
  404 for the new page and route, no "How work is checked" section, and no `#project-checks`
  link in the browser. The fixtures ran: migrated databases, connected projects through C-P3.5
  with their Engineer (`p-website`), the real service and the browser up to the project page.
- Found and fixed before the freeze: 9 hlint hints in the new tests (the first baseline run
  stopped at lint).
