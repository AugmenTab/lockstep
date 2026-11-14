# Contract — P6.2 Project command center (the project's Progress page)

- Contract ID: `C-P6.2@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-06.md` §6 (P6.2); PRD v0.4 FR-OBS-01; Plan v0.4 §4 P6.2; Bible v2.3 B23-13, B23-18.
- Basis: `phase-6` at `a1deaf9` (P6.1 accepted locally: full check PASSED, unit 923/923, integration 602/602).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What exists, and what this adds

The project page (C-P3.5) shows a project's setup and its task list; each task page (C-P3.6, C-P4.16) shows that
task's fix in detail with its checks, review and decisions. Nothing shows a project's work **as a whole**: what is
moving, what waits and exactly why, what is only technically verified, and what is Done. P6.2 adds one read-only page
per project, built from canonical rows at render time, with the existing page conventions (Beeline routes, Brigid
fragments, the shell, HTMX, the session rules). No new frontend architecture, no new authority, no form.

| # | Decision |
|---|---|
| C1 | **One typed standing per task** (`Lockstep.Kernel.Progress.Standing`), decided purely from its facts: the task's readiness (C-P3.6 K4, unchanged), whether it was handed over (C-P4.1), and its fix's state (C-P4.6 `TxState`) with the accepted commit. Precedence: canceled; then the fix's state (`Done` → **human-done**; `Accepted` → **technically-verified**; `Halted` → **waiting-for-you**; `Stopped` → **stopped**; `Running` → **active** at its step); then a Done task → human-done; handed over but not started → **queued**; otherwise its readiness → **proposed**, **ready**, **waiting** (the unfinished tasks it needs, by title), **blocked** (the reason), **cannot-start** (a needed task was canceled), **unknown** (a state Lockstep does not recognise — never shown as another). |
| C2 | **Technical acceptance is never Done.** `technically-verified` reads "Checked and committed on its own work branch (commit …). Not Done: you decide that on the task's page." Only `human-done` says Done. Every row states publication: **Not published** — Lockstep never pushes (publication arrives in P8); a local commit never implies published or integrated. |
| C3 | **Priority never disguises a dependency.** The page names one **next to hand over**: the highest-priority task whose standing is `ready` (then the oldest), by the existing `mostImportantReady`; a waiting, blocked or proposed task is never next, whatever its priority, and its row always shows its reason. |
| C4 | **What the page shows** (FR-OBS-01; handoff §6): the project; **the approved plan: none** ("Work comes from tasks you mark ready and hand over"; approved plans arrive with P6.4 — no plan revision is invented); counts per standing; *Waiting for you* (fixes stopped for a person's answer, linked to their task page); a table of every task: title (link to its page, the exact-record drilldown), where it came from (Lockstep, or `provider locator key @ revision` from C-P6.1), its standing in words, publication; who works and where: the Engineer, the folder and the checks (Profile id, version, digest) from the project's enablement, or that Lockstep may not work in it yet; **usage: not recorded** — Lockstep does not yet record provider token usage per project (B23-18: no figure is invented); **capsules**: not shown as consuming CPU or memory (the page does not read capsule state; it says where to look). |
| C5 | **Words, not internals** (FR-UX-06): the page says task, fix, checks, Done; it shows the typed standing's code only as a `data-standing` attribute for tests and tools. |
| C6 | **Read-only and truthful.** GET only; no form, so a stale or replayed browser view can change nothing. Without a session: 401 (the shell's S4 handling keeps the page to return to). Unknown project: 404. Database not ready: 503 with the shell's notice, never an empty "nothing to do". A task whose state cannot be read is `unknown`, never left out. |
| C7 | **Navigation and keyboard.** `/app/projects/<id>/progress` is a shell page (`ProjectProgressPage`) and `/app/fragments/project-progress/<id>` its fragment (`ProjectProgressFragment`); the shell routes it (`static/app.js` `routeFor` and the address list), so signing in again returns to it (S4). The project page links to it ("Progress"); the page links back. It is plain headings, one table with `th scope`, and links, reachable by keyboard. |

## 2. Typing

- Kernel (pure): `Lockstep.Kernel.Progress` — `WorkFacts`, `Standing`, `standingOf`, `standingCode`, `Publication`,
  `publicationCode`, `nextToHandOver`.
- Application: `Lockstep.Application.Progress` — `ProgressView`, `ProgressRow`, `loadProgress`.
- Web: `Lockstep.Web.ProgressPage` (`progressPage :: ProgressView -> LBS.ByteString`), routes in
  `Lockstep.Web.Routes.App`, dispatch in `Lockstep.Web.App`, the shell in `static/app.js`.

## 3. Verification (to be frozen)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/ProgressTest.hs` | unit, pure | C1, C2 (codes), C3 |
| `test/unit/Lockstep/Web/ProgressPageTest.hs` | unit: the renderer on a view with every standing | C2, C4, C5, C7 (structure) |
| `test/integration/Lockstep/ProgressPageTest.hs` | integration: the real service, real PostgreSQL, the real CLI (`backlog import`), HTTP; one real-browser journey | C1, C3, C4, C6, C7: keyboard to the page, sign-in ended and back to the same page |
| `test/unit/Main.hs`, `test/integration/Main.hs` | runners (additive) | registration |

Handoff §6 mandatory tests and where they are:

| Handoff case | Test |
|---|---|
| Multiple units with different statuses | unit page test (every standing); integration (proposed, ready, waiting, blocked, imported) |
| Priority cannot disguise a blocked dependency | Kernel `nextToHandOver`; integration (a High task waiting on a Low one) |
| Stale browser updates cannot create authoritative state | integration: the page has no form; POST to its address is not routed (no state changes) |
| Browser logout and reauthentication preserve context | browser journey |
| Human requests and review evidence remain accessible | unit page test (*Waiting for you* links; every row links to its task page, where checks and review are) |
| Technical verification is not rendered as Done | Kernel and unit page test |
| Published/integrated are not implied by a local commit | unit page test |
| Keyboard-accessible workflow and truthful failure states | browser journey (keyboard); integration (401, 404) |

The engine states (`active`, `waiting-for-you`, `technically-verified`, `human-done`, `stopped`) are rendered in the
unit page test from a constructed view; reaching them through the real engine is the P6.11 Gate D qualification.

## 4. Freeze record

- Frozen 2026-11-14 by the single writing agent, on `phase-6` after `a1deaf9`, with stubs for `standingOf`,
  `standingCode`, `publicationCode`, `nextToHandOver`, `loadProgress` and `progressPage`; the routes, dispatch, the
  project page's link and `static/app.js` are in place (they carry no behaviour of their own beyond routing).
- Frozen files (`scripts/format`, `hlint`: no hints, then `shasum -a 256`):

  | File | sha256 |
  |---|---|
  | `test/unit/Lockstep/Kernel/ProgressTest.hs` | `15d44efccfd388016e517405a2913c07e6cb7369f032b691e430b6835f03ecd8` |
  | `test/unit/Lockstep/Web/ProgressPageTest.hs` | `d7060d6fb0093520f870dc78099985455f97e644ec0aaa29258d24a3a39858d8` |
  | `test/integration/Lockstep/ProgressPageTest.hs` | `3c511b187a59443a9c3f6474fdd589c26c56e137c5e0a14fcd4ebee74c9a5e9f` |
  | `test/unit/Main.hs` (shared; supersedes earlier digests, additive) | `e806511bc6abd9aa52f8f2d0b71e6125759dce161eabbd7189060b221577105c` |
  | `test/integration/Main.hs` (shared; supersedes earlier digests, additive) | `250ab5fb70ddf73a2d0be7023b7eff25c316b36937824f09b98555d27d00ab87` |

- Baseline: unit **18 of 18 fail**; integration **2 of 3 fail** at the page itself (the fragment 404s; the browser
  never reaches "Next to hand over"). The third case (401 without a session, 404 for an unknown project, the shell
  served, a POST refused and nothing changed) **passes against the stub**: it guards refusals the routing already
  gives and must keep giving once the page exists; it is not evidence of the feature. Logs
  `.local/evals/phase-06/p62-baseline-unit.log`, `p62-baseline-integration.log`.

## 5. Allowed paths

New: the files in §2 and §3, `docs/gates/P6.2/**`. Changed: `src/Lockstep/Web/App.hs`, `src/Lockstep/Web/Routes/App.hs`,
`src/Lockstep/Web/ExecutionPages.hs` (export the step words), `static/app.js`, `package.yaml`/`lockstep.cabal`, the
two runners (additive), `docs/OPERATOR_GUIDE.md`.

## 6. Budget, stop, rollback

At most 3 attempts per failing frozen test. No provider call, no host change, no migration. Rollback: the branch.
