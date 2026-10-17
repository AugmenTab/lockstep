# Gate P0 — Governing Decisions and Source Acquisition: Gate Packet

- Report revision: 1, 2026-10-16
- Human gate decision: **PENDING.** Only the human owner can set it (§6).
- Tested basis: `AugmenTab/lockstep`, branch `v2`, commit
  `2486641258c204c81f2f5dbd8caa957e7c76f66d` (clean). Branch `main` and tag
  `python-v0.1-final` are at `8b045edb4100c4a8e8fe2275f7a7b597a1e944cb`.
- Policy identity: `manual — no v2 Supervisor` (Phase 0 handoff `.local/plans/phase-00.md`, sha256 `23265ae4…5ac0`)
- Judged against: Bible v2.1 `62196658…40ff`, PRD v0.2 `bbd407fd…7dfe`,
  Plan v0.2 `ae85b482…6345` (full digests in `docs/governance/SOURCE_REGISTER.md`)
- Schema follows `docs/VISUAL_EVIDENCE_CONTRACT.md` (itself still PROPOSED).
  Phase 0 uses the contract voluntarily. Default disposition is NOT_RUN.

## 1. Acceptance matrix

Executed by: manual agent session (one writing agent; two read-only subagents
for research and review). Environment: macOS (Darwin 25.6), git 2.50.1,
Python 3 (doc checks). No GHC, Stack or PostgreSQL on the host.

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P0-01@v1` Governing Bible/PRD/Plan identified by version and digest | inspection + `shasum -a 256` | rev, date, status, SHA-256 for each | Recorded; FR count 57 and NFR count 14 cross-checked | PASSED | `docs/governance/SOURCE_REGISTER.md` §2 |
| `AC-P0-02@v1` Human acceptance of Bible v2.1, PRD v0.2, Plan v0.2 recorded | human_review | explicit human decision | All three self-declare "proposed/draft"; no acceptance yet | **NOT_RUN** (awaiting §6 decision) | SOURCE_REGISTER §3 |
| `AC-P0-03@v1` Decision register DG-01…13 with owners, prerequisites, status | inspection | 13 gates, all owned by the human, none guessed | 13 recorded (DG-01 split a/b); DG-02…13 OPEN | PASSED | `docs/governance/DECISION_REGISTER.md` |
| `AC-P0-04@v1` Launchpad source available at an exact revision | `unzip -z`, `shasum -a 256` | commit SHA + archive digest | `11886bf73c2e…`, archive `696147a4…81efca` | PASSED | `docs/audits/LAUNCHPAD_AUDIT.md` §1 |
| `AC-P0-05@v1` Archive equals the private repo's commit tree | authenticated clone + tree diff | identical trees | Not executed (no authenticated access) | NOT_RUN | Audit §7; moved to P1.1 (C4) |
| `AC-P0-06@v1` Launchpad ownership, license and reuse rights decided | inspection + human_review | license basis + human declaration | BSD-3 declared, no LICENSE text; owner declared sole holder, BSD-3 into Lockstep | PASSED | Audit §2; `docs/adr/ADR-0001-launchpad-adoption.md` (ACCEPTED) |
| `AC-P0-07@v1` Direct third-party deps and assets license-checked | public GitHub API + pinned-commit files | license for each pinned dep and vendored asset | All permissive except pandoc (GPL-2.0, tools only, removed per C3) | PASSED | Audit §3–4 |
| `AC-P0-08@v1` Transitive Hackage license inventory | `stack ls dependencies --license` | no copyleft in shipped exe | Not executed (no toolchain); GMP/LGPL noted | NOT_RUN | ARCHITECTURE §5.2; moved to P1.1 |
| `AC-P0-09@v1` Reusable / unsupported / absent functionality distinguished | inspection | explicit lists | §5a reusable, §5b remove, §5c absent (CSRF, loopback bind, ordered migrations, dispatcher, tests, CI) | PASSED | Audit §5 |
| `AC-P0-10@v1` v2 repository strategy decided and executed | human_review + `git` | ACCEPTED decision; tag and branch exist | Orphan `v2`, one directory; `python-v0.1-final` → `8b045edb` | PASSED | `docs/governance/REPOSITORY_STRATEGY.md` execution record |
| `AC-P0-11@v1` Python remains a faithful, unmodified reference | `git rev-parse main`; `git merge-base main v2` | main = `8b045edb`; no common ancestor | main = `8b045edb…944cb`; merge-base exit 1 (none); nothing pushed | PASSED | §3 command log below |
| `AC-P0-12@v1` Regression lessons cover the six required classes | inspection | baseline, future imports, fixed outline, Planner escalation, durable human requests, recovery | PY-REG-01…11 cover all six plus three more | PASSED | `docs/governance/PYTHON_REGRESSION_LESSONS.md` |
| `AC-P0-13@v1` Module/dependency boundaries and build-command contract documented | inspection + independent review | layers, import rules, Launchpad mapping, `scripts/check`, dependency policy | Present; review findings F3/F11/F12 fixed | PASSED | `docs/architecture/ARCHITECTURE.md` sha256 `a635ad4d…46ec` |
| `AC-P0-14@v1` TESTING_STRATEGY covers every handoff-required topic and was independently reviewed | inspection + independent review | all 10 topics; review findings dispositioned | 10/10; findings F1, F2, F6–F10, F13 fixed | PASSED | `docs/TESTING_STRATEGY.md` sha256 `dd84cb98…b453`; §4 |
| `AC-P0-15@v1` VISUAL_EVIDENCE_CONTRACT covers every handoff-required topic and was independently reviewed | inspection + independent review | all 8 topics; no path to a false PASSED | 8/8; findings F4, F5, F14 fixed | PASSED | `docs/VISUAL_EVIDENCE_CONTRACT.md` sha256 `8cf49d27…96b2`; §4 |
| `AC-P0-16@v1` Gate-evidence wireframe is inspectable, labeled as illustration, shows all five dispositions, AA contrast | static_check (scratchpad script) + contrast computation | balanced HTML, no external resources, five badges, banner, contrast ≥ 4.5 | All checks ok; minimum contrast 6.02:1 (light and dark) | PASSED | `docs/gates/wireframes/gate-evidence-wireframe.html` sha256 `a927d3c2…5d89`; §3 |
| `AC-P0-17@v1` Human inspected the wireframe in a browser | human_review | human opens the file and comments | Not yet | **NOT_RUN** | — |
| `AC-P0-18@v1` Scaffolding compiles cleanly | build | n/a: no Haskell source exists on `v2` | No scaffolding was changed | NOT_RUN (not applicable; `required: false`) | `git ls-files` on `v2` has no `*.hs` |
| `AC-P0-19@v1` P1.1 bootstrap Contract specifiable against actual source and approved policy | inspection | bounded Contract citing the audited source | Proposal in §5 | PASSED | §5 |

**Machine summary (required rows, worst effective disposition):** `NOT_RUN`
(rows 02 and 17 await the human; rows 05 and 08 are deferred into P1.1 as
explicit C4 checks). The summary is not acceptance.

## 2. Accepted deviations requested

| Row | Request |
|---|---|
| `AC-P0-05`, `AC-P0-08` | Accept Gate P0 with these two checks **deferred to P1.1 acceptance** (ADR-0001 C4). Rationale: both need a Haskell toolchain/clone that P1.1 brings anyway. They remain NOT_RUN here. |

## 3. Command log (reproducible)

```sh
shasum -a 256 .local/LOCKSTEP_PROJECT_BIBLE_v2.1.pdf .local/LOCKSTEP_V2_IMPLEMENTATION_PRD_v0.2.pdf \
  .local/LOCKSTEP_V2_DEPENDENCY_AWARE_PLAN_v0.2.pdf .local/launchpad-main.zip
unzip -z .local/launchpad-main.zip                     # → 11886bf73c2e3ac69a6839af28b97ba79bbee5fb
git rev-parse main 'python-v0.1-final^{commit}'        # → 8b045edb… (both)
git rev-list --max-parents=0 v2                        # → b6f59f45… (orphan root)
git merge-base main v2; echo $?                        # → (no output) 1
python3 -I <scratchpad>/check_p0_docs.py .             # → 10/10 ok, exit 0
```

The doc-check script and contrast computation ran from the session scratchpad.
They are evidence of a P0 check, not a repository tool. `scripts/check` replaces
them from P1.1.

## 4. Independent review disposition

A read-only reviewer agent checked the four P0.4 artifacts against the handoff,
the Bible, the PRD and the Plan. It reported 7 MAJOR and 9 MINOR findings. All
were addressed in `2486641`, except F16 (the missing P1.1 Contract), which is
addressed by §5 of this report.

| # | Sev | Finding (short) | Disposition |
|---|---|---|---|
| F1 | MAJOR | Sentinel guard could pass vacuously or reach the real CLI on dev hosts | Fixed: `scripts/check` installs and asserts shims on every host; negative test aborts as NOT_RUN unless the shim resolves |
| F2 | MAJOR | Live adapter constructible only from smoke authorization, which blocks production | Fixed: separate operator production config vs smoke authorization; neither available to tests |
| F3 | MAJOR | Foundation both leaf and wiring root | Fixed: explicit composition root `app/lockstep/Main.hs`; Foundation is a leaf |
| F4 | MAJOR | `required` flag unversioned; empty gate vacuously PASSED | Fixed: REV bump + deviation record; empty required set aggregates to NOT_RUN |
| F5 | MAJOR | Stale PASSED could render green | Fixed: renders/counts as `INCONCLUSIVE (stale revision)`; wireframe shows it |
| F6 | MAJOR | PRD §10.1 layers missing (HTTP, projection, adapters, E2E UI) | Fixed: TESTING_STRATEGY §2.1 |
| F7 | MAJOR | Fixture schema had no human/operator/external inputs | Fixed: step kinds added; example made coherent |
| F8–F10, F13 | MINOR | Sandbox writes; canonical trace encoding; release-build fault refusal; DG-02 wording | Fixed |
| F11 | MINOR | "Already compiles with Henforcer" unverified | Reworded to "configured" |
| F12 | MINOR | Wrong Bible citation; GMP/LGPL; kernel allowlist | Fixed |
| F14 | MINOR | ID scheme, method.kind, evidence rules inconsistent | Fixed |
| F15 | MINOR | Wireframe a11y/fidelity | Fixed; contrast measured (min 6.02:1) |
| F16 | MINOR | No P1.1 bootstrap Contract | §5 below |

## 5. Proposed P1.1 bootstrap Contract (PROPOSED, not frozen)

| Field | Value |
|---|---|
| Work Unit | P1.1: minimal Launchpad-derived Haskell package with a health page |
| Basis | Branch `v2` at the Gate P0-accepted commit; Launchpad `11886bf` from `.local/launchpad-main.zip` (sha256 `696147a4…81efca`) |
| Objective | Bring Launchpad into `v2` as the `lockstep` package. Strip the ADR-0001 removals, rename `Launchpad.*` to `Lockstep.*` per ARCHITECTURE §1/§3, and serve a Brigid-rendered liveness page plus `GET /api/health_check` → 204. Bind `127.0.0.1` by default with a configurable port. |
| Traces | FR-APP-01, FR-APP-02 (partial); NFR-07, NFR-11 |
| Allowed paths | `package.yaml`, `stack.yaml`, `stack.yaml.lock`, `app/lockstep/**`, `src/Lockstep/{Foundation,Web}/**`, `static/**`, `test/unit/**`, `scripts/check`, `Dockerfile`, `henforcer.toml`, `.hlint.yaml`, `fourmolu.yaml`, `LICENSE-LAUNCHPAD` (BSD-3 text), `THIRD_PARTY_LICENSES.md`, `README.md`, `docs/gates/P1.1/**` |
| Out of scope | DB connection/migrations (P1.2, DG-02); auth/CSRF (P1.3); commands (P1.4); dispatcher (P1.5); any Kernel module; any provider adapter |
| Tests first (Planner-authored, frozen before implementation) | `test/unit`: (1) the config parser defaults host to `127.0.0.1` and rejects a missing port with a typed error; (2) the Rollbar config block is **absent**, and a config containing it is rejected; (3) the rendered liveness page contains no Pico class and no `_hyperscript` reference; (4) the route table contains only health/liveness routes (no signup/admin/account/mobile/swagger) |
| Acceptance | (a) `scripts/check` steps 1–4 exit 0 from a clean clone in the dev container. (b) `lockstep serve` returns 204 on `/api/health_check` and the liveness page on 127.0.0.1, and is unreachable on a non-loopback interface by default. (c) No `pico*`, `_hyperscript`, rollbar, pandoc, nginx or ssh-mount remains (`git grep` check). (d) ADR-0001 C4: `stack ls dependencies --license` has no copyleft in the `lockstep` exe (GMP linkage recorded), `THIRD_PARTY_LICENSES.md` and the Launchpad BSD-3 text are present, and an authenticated clone of `11886bf` is tree-diffed against the archive. (e) Henforcer configured; a deliberately violating fixture fails compilation. (f) Gate evidence recorded per VISUAL_EVIDENCE_CONTRACT. |
| Verification commands | `docker build …` (dev image); `scripts/check`; `stack ls dependencies --license`; `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:<port>/api/health_check` |
| Budget / stop | Max 3 implementation attempts; stop and ask the human if the container build fails for reasons outside allowed paths, or if any C4 check finds copyleft or a tree mismatch |
| Human decision points | Freeze of the tests above; port default; final P1.1 acceptance |
| Rollback | Revert the P1.1 commits on `v2`; `main` is unaffected |

## 6. Final approval packet

### 6.1 Already resolved (not reopened)

DG-01a (Launchpad `11886bf` adopted under BSD-3; `_hyperscript` and pandoc
removed), DG-01b (orphan `v2` branch), the one-directory layout, and
private-for-now distribution (ADR-0001, REPOSITORY_STRATEGY).

### 6.2 Governing specifications under decision

| Document | Revision / date | Self-declared status | SHA-256 |
|---|---|---|---|
| Project Bible | v2.1, 2026-10-16 | Draft for human review | `62196658858675c450f1e13e561724900f27827db7b41ea774ad16ac4ba640ff` |
| Implementation PRD (LS-V2-PRD) | v0.2, 2026-10-16 | Proposed for human review | `bbd407fd57285ac6d8da6deee3995a5771c9c111a5c0b62e2df81730ebc17dfe` |
| Dependency-aware plan (LS-V2-PLAN) | v0.2, 2026-10-16 | Proposed; entirely provisional | `ae85b482d17d43e2fec106e1a857ef2f68f7d1b0c1eb7d0021ecfc64dbfe6345` |

The three documents are mutually consistent (SOURCE_REGISTER §2). Two
presentation issues are recorded, neither of which changes a requirement: the
Bible has no Markdown source, and its PDF layout is broken across pp. 15–46.

### 6.3 Design contracts under decision (consequential choices)

**[ARCHITECTURE.md](../../architecture/ARCHITECTURE.md)**
- One package and one executable: the CLI and `serve` share the same operations.
- Only one place may construct a live model provider: the composition root
  `app/lockstep/Main.hs`, plus the separate smoke executable. A static check
  enforces this.
- The kernel is pure, with a closed dependency list. Henforcer enforces the
  import rules once the first kernel module lands (P2.1).
- `scripts/check` is the single verification entry point.
- Dependencies are pinned, `allow-newer` is off, and there is a permissive
  license allowlist. GHC's LGPL libgmp linkage must be decided before any
  distribution.

**[TESTING_STRATEGY.md](../../TESTING_STRATEGY.md)**
- Scripted adapters return the same typed outcome as live ones. A model call no
  fixture covers fails the test; nothing falls back to a live model.
- Fixtures can inject operator, human, external and clock inputs. Their writes
  are confined to a per-test sandbox.
- PostgreSQL, Git and processes are real in integration tests. Named fault points
  kill the actual process, and the release build refuses fault plans.
- No live model calls, by construction: stub provider CLIs on every host, no
  credentials, no network for unit tests, and a construction gate on the live
  adapter. Live smoke tests need an expiring, budgeted authorization file.

**[VISUAL_EVIDENCE_CONTRACT.md](../../VISUAL_EVIDENCE_CONTRACT.md)**
- Five statuses, NOT_RUN by default, no coercion to PASSED.
- Outdated, changed or missing evidence shows INCONCLUSIVE. An empty required
  set shows NOT_RUN. Changing the `required` flag bumps the version and needs a
  deviation record. There is no "waived" status.
- Only a human records the gate decision, bound to the report digest.
- WCAG AA contrast and text statuses are required.

### 6.4 Wireframe for inspection

[gate-evidence-wireframe.html](../wireframes/gate-evidence-wireframe.html). Open
it from the repo root with `open docs/gates/wireframes/gate-evidence-wireframe.html`.
It uses sample data only and shows all five statuses, a stale pass rendered as
INCONCLUSIVE, the evidence drill-downs and a disabled decision form. Every color
pair meets WCAG AA (minimum contrast 6.02:1).

### 6.5 Consequences of deferring AC-P0-05 and AC-P0-08 to P1.1

Both rows stay NOT_RUN here. Each becomes a P1.1 acceptance condition (§5 (d)).
Neither blocks P1.1 work from starting; both block P1.1 from being accepted.

| Row | Unproven until then | P1.1 must | If it fails |
|---|---|---|---|
| AC-P0-05: archive equals private commit `11886bf` | That the audited archive bytes (`696147a4…`) are exactly that commit. The only evidence is GitHub's archive comment. | Clone `11886bf` with authentication and diff its tree against the archive | P1.1 stops. Re-audit the real tree; ADR-0001 is revisited only if the license or source findings change. |
| AC-P0-08: transitive license inventory | Licenses of the Stackage dependencies, and how GMP is linked | Run `stack ls dependencies --license`; record GMP linkage and `THIRD_PARTY_LICENSES.md` | Copyleft in the shipped executable stops P1.1 and needs an ADR. There is no distribution exposure while v2 is private. |

### 6.6 Open item: one human decision

The only blocker is a **single Phase 0 gate decision** covering 6.2–6.5:
adopting the three specifications, approving the three design contracts,
inspecting the wireframe (AC-P0-17) and accepting the deferral in 6.5.

| Field | Value |
|---|---|
| Decision | _pending_ |
| Decided by | _pending_ |
| Decided at | _pending_ |
| Report revision / sha256 | 1 / _computed at decision time_ |
| Notes | _pending_ |
