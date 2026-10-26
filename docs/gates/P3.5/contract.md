# Contract — P3.5 Guided project setup

- Contract ID: `C-P3.5@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.5; PRD v0.3 FR-UX-05 (with FR-WRK-01/02, NFR-15); Plan v0.3 §4
  P3.5 ("guided project create/import, Repository/Engineer binding and safe defaults; distinguish
  organized project from execution-enabled Engineer"; verification "new and existing repo,
  alias/fork identity, invalid paths and ownership, no remote publication, safe partial setup");
  DG-03 (C-P2.1, D-3.7: identity is observed in the filesystem view where the Engineer will run
  Git; a host repository needs a path-preserving mount, left to Phase 3); owner decision DR-P3.1
  (host authority stays in the helper; the pane and service get no Docker socket).
- Writer: the single writing agent (Implementer, manual).
- Scope: projects, their folders and the Repository/Engineer binding. Tasks (P3.6), Profiles
  (P3.7) and running any code (Phase 4) are **not** here.

## 1. What P3.5 delivers

1. **Projects in the application.** Under **Projects** a person names a project, says in their own
   words what it should achieve, and picks where it lives: a new folder Lockstep makes (the
   default), a folder already on this computer, or "decide later". They see each project's setup
   status in plain words. No Git word is needed on the ordinary path.
2. **Folders Lockstep may see are decided on the host.** The control pane gains **Project
   folders**: the folder Lockstep keeps its own projects in, and the existing folders the person
   adds. Only the host-side helper changes this list; the service sees exactly these folders, at
   the same paths, and nothing else of the computer.
3. **The DG-03 binding.** A project with a folder is bound to one Repository owned by one Engineer
   of its own, registered by the C-P2.1 operation unchanged (alias, linked worktree, submodule,
   bare, shallow and same-remote refusals included), observed in the service's view, which is the
   view later Engineers will run Git in.
4. **Organized is not executable.** A project can be organized with or without a folder. Nothing
   in P3.5 can run code, change a person's existing folder, create a remote or push.

## 2. Decisions

| # | Decision |
|---|---|
| J1 | **Projects table** (migration 13, `lockstep_projects`): `id` uuid; `name` 1–80 characters, no control characters, unique ignoring case; `outcome` 0–2000 characters (new lines and tabs allowed); `creation_key` unique (the C-P1.5 idempotency-key rule); `setup` one of `organized`, `connected`, `setup-failed`; `setup_refusal` (a code, set exactly when `setup-failed`); `folder` (the path connected); `engineer_name` (the project's Engineer, once chosen); `repository_id` unique, references `lockstep_repositories`; `revision` from 1; `created_at`, `updated_at`. |
| J2 | **Typed operations** (`Lockstep.Application.Projects`): `createProject` (creation key, name, outcome, folder choice), `connectProject` (expected revision, folder choice), `listProjects`, `findProject`, `offeredFolders`. Name and outcome are checked first; a refused one creates nothing. A repeated creation key returns the project it created and creates nothing. A stale revision is refused and changes nothing. The C-P1.5 workspace receipts belong to the workspace revision and are not reused. |
| J3 | **Folder choices.** `new`: Lockstep makes `<projects folder>/<slug>` (from the name: `a-z`, `0-9` and `-`, at most 36; `-2`, `-3`… past an existing file or folder, which is left alone) and runs `git init` there with branch `main`, no commit and no remote. `existing <path>`: one of the offered folders (J7), exactly as offered. `later`: no folder. A folder that is refused leaves the project created with `setup-failed` and the code; **Try again** is `connectProject` with the current revision. Each connection attempt is one revision. |
| J4 | **Engineer binding.** The first connection attempt chooses the project's own Engineer, `p-<slug>` (`-2`… if the name is taken), creates it (C-P2.1 `addEngineer`) and keeps its name on the project; later attempts reuse it. Registration is the C-P2.1 `registerRepository`, unchanged; with several remotes and no choice it is tried again with `origin` when that exists (a fork keeps its own origin). Folder checks that need no Git (J7) come before the Engineer exists. The Engineer has no Profile and no executor; the page says "Lockstep can see this folder. It cannot change it or run anything in it yet." |
| J5 | **Project folders (host authority).** The helper keeps `helper/folders`: at most one line `rw <path>` (the projects folder, first) and up to 15 lines `ro <path>` (added folders), canonical absolute paths. The projects folder exists only when the helper is given `--projects DIR` (the launcher passes `$HOME/lockstep-projects` for the operator's own Lockstep, never for an instance); the helper makes it. The helper writes the same bytes to `pane/folders` for the pane to show. It runs `scripts/service` with `LOCKSTEP_SERVICE_FOLDERS` naming the list; `scripts/service` (`start`, `cli`, `open`) then mounts each listed folder that exists at its own path (`rw` read-write, `ro` read-only), passes `LOCKSTEP_PROJECT_FOLDERS` (the projects folder or nothing, then the added folders, joined with `:`), and runs the container as the host user (`--user uid:gid`) so Git sees the owner it expects. Without `LOCKSTEP_SERVICE_FOLDERS` the container runs exactly as before. |
| J6 | **Adding a folder** is a fifth signed request kind, `lockstep-folder-request 1` (`requests/<id>.freq`, seven lines), op `add-folder`, `expect folders-<16 hex>` (the first 16 hex of SHA-256 of the list the person reviewed), and `path <absolute path>` (printable ASCII, no `:` or `,`, no empty, `.` or `..` segment). The helper resolves it on the host (`cd -P`, `pwd -P`) and refuses with: `state-changed` (the list changed), `unusable-path`, `folder-missing`, `not-a-folder`, `outside-home`, `home-folder`, `inside-lockstep` (the checkout or anything in it), `already-listed`, `overlaps-listed` (inside or around a listed folder), `list-full`. On success it appends `ro <canonical path>`, updates `pane/folders`, and restarts the service if it runs; the result carries `service.restart ok`, `failed` or `not-needed`. The pane's `GET /api/folders` returns the list and its digest; `POST /api/folders` (body `add-folder <expect> <path>`) writes the request. |
| J7 | **Offered folders.** The service offers as existing folders only: each direct child of the projects folder, and each added folder, that is a real directory (not a symbolic link) holding a `.git` directory, and that no project has connected. It never walks further and never offers anything outside `LOCKSTEP_PROJECT_FOLDERS`. `existing <path>` that is not exactly an offered path is refused (`folder-not-offered`) before Git runs. |
| J8 | **No remote publication.** No P3.5 code path runs a Git command that contacts a network or writes to a person's folder: `git init` runs only for `new`, only inside the projects folder; registration uses the C-P2.1 read-only observation; added folders are mounted read-only. Remotes already present are recorded as DG-03 records them and are never used. |
| J9 | **Pages.** `/app/projects` (overview: each project as a link with its status, and a **New project** link; no form or button, so the C-P3.4 rule for unbuilt sections still holds for the overview), `/app/projects/new` (the form) and `/app/projects/<id>` (one project, with **Try again** when its setup failed) are shell addresses; their fragments are `/app/fragments/projects`, `/app/fragments/project-new` and `/app/fragments/project/<id>`. `POST /app/api/projects` and `POST /app/api/projects/<id>/connect` take a form (session header, Origin, body up to 16 KiB) and answer `200` with the page to show: the project page (and `X-Lockstep-Path: /app/projects/<id>`), or the form again with what was typed and the reason in words. The form's creation key is made by the service when it renders the form. All text is escaped. |
| J10 | **Plain words** for every refusal (the C-P2.1 codes and the P3.5 codes), with no Git vocabulary; Advanced keeps the exact code. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Foundation/FolderProtocolTest.hs` | unit | the folder request kind: vector (`openssl`), list digest (`shasum`), allowlist `add-folder`, `expect folders-<16 hex>` only, path grammar, kinds do not mix, malformed and oversized files |
| `test/unit/Lockstep/Kernel/ProjectTest.hs` | unit | name and outcome rules, slug and candidates, Engineer name, folder choices, setup states, plain words for every code with no Git vocabulary |
| `test/integration/Lockstep/ProjectsTest.hs` | integration: real PostgreSQL, real Git in temporary folders, the operations in-process | the folder variable; `new` (folder made, `git init` on `main`, no history, no remote, its own Engineer, revision 2); taken names and taken folder names; rules first; repeated creation key; `existing` connected with the folder unchanged byte for byte; only offered folders (outside, plain, nested, link, worktree, missing, unnormalized path refused before any Engineer); a copy and a same-remote clone refused, a fork connected; shallow refused then Try again (stale revision refused, already connected, unknown project); decide later; no projects folder; text stored exactly |
| `test/integration/Lockstep/ProjectsPageTest.hs` | integration: real service with `LOCKSTEP_PROJECT_FOLDERS` | the form (fields, default, key, no Git words); session and Origin required; the project page and its address; the overview's links and no form or button; only offered folders listed, a forged path refused in words with Try again; a taken name explained on the form with the text kept; a stale Try again explained; escaping; 404s; 16 KiB limit |
| `test/integration/Lockstep/FolderHelperTest.hs` + `Support/Folders.hs` | integration: real helper and `scripts/service` in a checkout inside a temporary home, a `docker` stub that records calls and starts the real service as the container would; the real pane | the list and its pane copy; no projects folder without `--projects`; a link resolved to its real path; no restart when stopped; a restart with the new mounts when running; a stale review; every J6 refusal; 15 added at most; exact mounts, `--user` and `LOCKSTEP_PROJECT_FOLDERS`; unchanged without a list; the pane's list, digest, session, Origin, body checks and a full add |
| `test/integration/Lockstep/ProjectsBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen) | pane → Project folders → add a folder (the service restarts with it) → Open Lockstep → keyboard to Projects → New project → a project in a new folder → its page → a project in the added folder → the overview lists both |

Page wording the tests rely on: the pane's `Project folders`, `#folder-path`, `#folder-review`,
"Lockstep will be able to see this folder", `#add-folder`, "Lockstep can now see"; the
application's `#new-project`, "What should it achieve", `#project-name`, `#project-outcome`,
`#folder-existing`, `#folder-choice`, `#create-project`, "Lockstep can see this folder", "cannot
change it or run anything in it yet", "not one of the folders Lockstep can see", "Try again",
"already has a project with this name", "changed since this page was shown".

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the application, pages, pane and helper
parts were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/FolderProtocolTest.hs` | `f94ddbce675e98a8f9247a0e9a5f0276a05d48446c96285127f3e17144e369fd` |
| `test/unit/Lockstep/Kernel/ProjectTest.hs` | `1270f1135db5c9051c488f04942571b30938d71f0bfc19e95d95438b9ffaa566` |
| `test/integration/Lockstep/ProjectsTest.hs` | `0e47aac63eb0874a85ed0faa7d1bb7c7ef5951e42d8d4c8188798bb2bade5342` |
| `test/integration/Lockstep/ProjectsPageTest.hs` | `de7f5a0569b710df3bd4bd0e1d1e93c077a815c47f275100b6fee9a41e6925e6` |
| `test/integration/Lockstep/FolderHelperTest.hs` | `0eca3df2e263f8275d53949a6afe68429c31fa3d5b01d9ec50a3cd23dd140679` |
| `test/integration/Lockstep/Support/Folders.hs` | `2000c206ff62bd7fe6f9978b8de456b020cc7f417816a99181b9bc56bdb86579` |
| `test/integration/Lockstep/ProjectsBrowserTest.hs` | `2bbd46d30b67198021ef56b787233d7a8b93b3dc020e12588eafc9384f7e0101` |
| `test/unit/Main.hs` (runner, additive) | `c72d56a1af8af3c8bfa53444c221f77f9031cebe7aba2d174e4618e7bcbefdb6` |
| `test/integration/Main.hs` (runner, additive) | `b7135387bf098fac87a30f583a1c2055a54d26efd4dc866716beeed9d2301b5c` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- Unit baseline against type-only stubs (`prefreeze-unit-baseline.log`): 18 of 21 new cases fail;
  the HMAC vector (through C-P3.1 `hmacHex`), "kinds do not mix" and "rule errors refuse rather
  than truncate" pass. The folder codec and the pure project rules were then implemented before
  the freeze, as in P3.1–P3.4, because the fixtures use them; all 21 pass.
- `scripts/check --integration` against stubbed project operations and the unchanged service,
  pane and helper (`prefreeze-integration-baseline.log`): format, lint, build, unit (763) and
  guard pass; 32 of 326 integration cases fail: the 2 known `HandoverTest.hs` cases
  (`docs/gates/P3.4/test-amendment-request.md`) and 30 of the 31 new cases. **Each new failure was
  read for its reason**: the stubbed operations ("not ready", nothing offered, an unparsed
  folder variable), 404 for the new pages and routes, no folder list from the helper, no mounts
  from `scripts/service`, no folder routes or controls in the pane. The fixtures ran (migrated
  databases, real Git, the real service, helper, pane and browser up to the pane). The one new case
  that passes, "without a folder list, scripts/service runs the container exactly as before", is
  unchanged behaviour by design.
- Found and fixed before the freeze: nine lint hints (two in the project rules); the test's
  creation keys were shorter than the C-P1.5 key rule allows (16), so those cases failed in the
  fixture instead of on behaviour — fixed and the baseline run again.
