# Contract — P3.10 UX and accessibility hardening

- Contract ID: `C-P3.10@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.10 ("verify complete user journeys, not only individual
  endpoints"; "actual browser interaction"; "keyboard interaction and smaller screens";
  "understandable errors, contextual guidance and sensible empty states"; "prepare a predefined
  usability test for real participants"; "automated tests cannot impersonate human participants
  … leave unperformed human tests explicitly NOT_RUN"); PRD v0.3 FR-UX-10, NFR-15; Plan v0.3 §4
  P3.10 ("accessible labels, first-time task flow, record assistance honestly").
- Writer: the single writing agent (Implementer, manual).
- Scope: one automated first-use journey across every section in a real browser, by keyboard
  and at phone width, with an accessibility sweep of each page it visits; the copy fixes that
  journey needs; and the predefined procedure for testing with real people, whose results are
  **NOT_RUN** until real people take part.

## 1. What P3.10 delivers

1. **A first-use journey, end to end, in a real browser.** Sign in → Home → Projects (by keyboard)
   → a new project in a new folder → a task, made ready → How work is checked → Always-on rules
   only, saved by keyboard → Decisions (nothing to decide) → Activity (nothing has happened yet)
   → a second project decided later. On every page: exactly one main heading, and every visible
   form control has a label.
2. **Phone width.** At 390 × 800 CSS pixels, every section and the project, task and checks pages
   have no horizontal scrolling.
3. **True words.** The Projects overview no longer says tasks arrive later (they arrived in P3.6);
   it says what still arrives later (running the work). Any control the sweep finds without a
   label gets one.
4. **The real-novice test, ready to run.** `usability-protocol.md`: who takes part, the
   predefined journeys, what the facilitator may and may not say, what counts as assistance, what
   is recorded, and a results table that stays NOT_RUN until real participants take part.

## 2. Decisions

| # | Decision |
|---|---|
| O1 | **The journey** is one frozen browser test (`FirstUseJourneyTest.hs`) against the real service, a migrated real database and a temporary projects folder; it uses only clicks, typing, Tab, Space and Enter through the frozen driver, never a constructed HTTP request. |
| O2 | **Accessibility sweep** (in the page, after each page loads): inside `#content`, every `input` (not hidden), `select` and `textarea` has a `label[for=id]` or an `aria-label`, and there is exactly one `h1`. |
| O3 | **Phone width**: `document.documentElement.scrollWidth <= window.innerWidth` after each page loads at 390 × 800. |
| O4 | **Copy**: Projects overview: "Running the work inside a project arrives in a later update of Lockstep." (the frozen C-P3.4 rule that the overview says "later update" still holds). The connect form's folder list gets `aria-label="Folder"`. |
| O5 | **Human results are never automated.** The protocol's results are filled in only from real sessions; until then every journey is NOT_RUN. An automated pass is recorded as automated evidence only. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/FirstUseJourneyTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen), real service | O1–O4 along the whole journey; nothing is scheduled or run by it |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| Frozen files (P3.10 and earlier) | digests unchanged | §4, earlier contracts' §4 |
| `scripts/check --integration` | format, lint, build, unit, no-live-model guard PASSED; integration 380 of 382 PASSED, the 2 failures being the known C-P3.4 `HandoverTest.hs` defect | `check-integration.log` |
| C-P3.10 journey | PASSED (337 s): every page swept (labels, one heading), every page narrow at 390 px, true words on Projects, keyboard steps, counts (2 projects, 1 task, no work order, no schedule decision) | `check-integration.log` |
| Real novices (C9) | **NOT_RUN** — the procedure is ready (`usability-protocol.md`) | — |
| Linux clean clone | see the Gate C package | `docs/gates/C/` |

Two implementation runs: in the first, the journey passed but the C-P3.8 browser case timed
out in its driver (the run took 2870 s, twice its usual time; the date rolled over during it).
The second run, with no change, passed everything but the known 2. The first is kept as
`check-integration-run1-browser-timeout.log`.

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the copy fixes.

| File | SHA-256 |
|---|---|
| `test/integration/Lockstep/FirstUseJourneyTest.hs` | `8d88f4a6ef6a8cf24697b27efe89a32e17f028af4eb321c90698e8ecf5156ed0` |
| `test/integration/Main.hs` (runner, additive) | `a04db0de5376296720775e88eea6b22790e5357da06d2ec3b97ee79edac27f42` |

Earlier frozen tests are untouched; the runner only gains lines.

Pre-freeze verification (`prefreeze-integration-baseline.log`): format, lint, build, unit and
guard pass; 3 of 382 integration cases fail: the 2 known `HandoverTest.hs` cases and the new
journey, on exactly one check: `truewords` (the Projects overview still says "Tasks inside a
project arrive in a later update"). Every other step of the journey already passed: all ten
accessibility sweeps, all ten phone-width checks, the keyboard steps and the counts. The journey
took 336 s against its 400 s limit; noted as the margin to watch.

The connect form's folder list had no label of its own; the journey did not reach it (no folder
was offered), so O4's `aria-label` is a fix the sweep did not force. It is made anyway.
