# Early value checkpoint — dogfood (for the owner)

- Status: **PASSED — run by the owner 2026-10-27**: steps 1–11 PASSED, with 2 findings below
  (one product gap, one error in this document).
  Results are as the owner reported them in the session; the writing agent recorded them and did
  not observe them. Prepared 2026-10-26; brought up to date 2026-10-27 after the Planner
  disposition, by the writing agent, manual.
- Authority: Plan v0.3 §2.1 "Early value checkpoint: As soon as P3.5–P3.6 are green, run a real
  browser dogfood that launches Lockstep, registers one existing repository, and creates one
  source-linked task. It is not Gate C-UX acceptance or agent execution." Planner disposition
  2026-10-27: "get the owner using Lockstep".
- Why the agent does not run it: it uses your own installation, home folder and default browser
  (`./lockstep` with the real browser is owner-only), and it upgrades your installation.

## Where you start

- Your installed Lockstep today: commit `6c2851d`, database schema 5 (`.local/install/VERSION`).
- What you upgrade to: the tip of `phase-3` (database schema 15). It is the build the Gate C
  checks ran against: the tested code plus the approved `HandoverTest.hs` fix and documents.

## Before you start (2 minutes)

1. Docker is running (OrbStack).
2. In a terminal: `cd ~/personal/lockstep`, then `git switch phase-3` and `git status`. Expected:
   "nothing to commit, working tree clean". The pane refuses to prepare an upgrade from a
   checkout with uncommitted changes.
3. Pick one existing Git folder of your own under your home folder, e.g. a small personal
   repository. Lockstep only reads it: it is mounted read-only and nothing is pushed. Note its full
   path. To confirm afterwards that nothing changed, run `git status` in it now and keep the output.

## Steps (about 15–20 minutes; the build takes most of it)

| # | Do | Expected | Result |
|---|---|---|---|
| 1 | In the terminal: `./lockstep` | The control pane opens in your default browser and says the installed version | PASSED (the pane was built on first use, then opened) |
| 2 | **Version** → **Prepare an update** → wait → **Review and upgrade…** → **Upgrade now** | The pane backs up the database, checks the backup, upgrades it (schema 5 → 15), starts the new version: "Done: Lockstep was upgraded." | PASSED (now `b963527`) |
| 3 | **Project folders**: the first line is `~/lockstep-projects`. Type the full path of your folder → **Review…** → **Add folder** | "Done: Lockstep can now see …"; the service restarts | PASSED |
| 4 | **Open Lockstep** | Lockstep's Home opens in the browser, signed in | PASSED |
| 5 | **Projects** → **New project**: a name, what it should achieve, **In a folder that is already on this computer** → your folder → **Create project** | "Lockstep can see this folder: …" and "It cannot change it or run anything in it yet" | PASSED |
| 6 | On the project page: **New task** → what needs doing, what done looks like, priority → **Add task** → **Mark as ready to work on** | "Ready to work on."; the project page says "Most important task ready to work on: …" | PASSED |
| 7 | On the project page, under **How work is checked**: **See or change how work is checked** → **Always-on rules only** → **Save** | "Saved."; the project page then says "Chosen: Always-on rules only." Nothing runs | PASSED |
| 8 | **Decisions** | "Nothing needs your decision right now." (no work has run) | PASSED |
| 9 | **Activity** | "Nothing has happened yet." | PASSED |
| 10 | In the pane: **Service** → **Stop**; **Database** → **Stop**, then **Start**; **Service** → **Start** → **Open Lockstep**. (`./lockstep stop` stops only the pane; the service and database keep running) | The project, task and checks are still there with the same words | PASSED |
| 11 | In your registered folder: `git status` | The same as before you started: Lockstep changed nothing | PASSED |

Nothing in these steps runs an agent or a model, and nothing is pushed anywhere. Running work
inside a project arrives in a later update.

## If something goes wrong

- The upgrade fails in step 2: the pane keeps the previous version and the verified backup, and
  says so (C-P3.3). Record its words; don't retry more than once.
- Any other step fails: record the exact words on the page and the step number. Your registered
  folder is untouched either way.

## Findings from the owner's run (2026-10-27)

1. **`lockstep stop` ran the wrong program.** In the owner's terminal, `lockstep` resolved to
   `.venv/bin/lockstep`, an old Python entry point of the same name, which failed with
   `ModuleNotFoundError: No module named 'lockstep'`. Nothing was stopped or harmed. The step
   originally said `lockstep stop`; it now says `./lockstep stop`. The product gap stays open for
   the owner: an active virtual environment, or anything else earlier on `PATH` named `lockstep`,
   shadows the command the launcher offers to install in `~/.local/bin` (`offer_path` returns
   early only when `command -v lockstep` is already that file). Not fixed; reported.
   **Planner disposition (2026-10-27): a product finding.** Addressed by C-C.R1 R12
   (`docs/gates/C-R1/contract.md`): `lockstep setup-path` and an interactive `./lockstep` name the
   other program, point to an active virtual environment when it is the cause, and say to run
   `./lockstep` (or the checkout's full path); nothing outside Lockstep's own link is touched. The
   setup instructions (README, OPERATOR_GUIDE) say the same. Tested automatically (a `.venv`
   `lockstep` first on `PATH`); not yet seen by the owner in their own terminal.
2. **Step 10 was wrong in this document.** `./lockstep stop` answered "Stopped the Lockstep
   control pane. The Lockstep service and database keep running.", which is correct behaviour
   (C-P3.2), so reopening would not have tested that the data survives a restart. Step 10 now
   stops and starts the service and database from the pane. The writing agent's error, not the
   product's. Resolved (Planner, 2026-10-27).

## What was tested, and what was installed (provenance)

The owner ran these steps on the installed build of **`b963527`** (`.local/install/VERSION`:
`commit b963527…`, `dirty false`, binary SHA-256 `72ce6570…7c5b`, installed 2026-10-27T20:32:42Z,
database `ready 15`; the binary's SHA-256 was checked against that record). The Gate C machine
qualification ran on **`bd94c96`**. The two commits are different identities with the same code:
`b963527` is `bd94c96` plus four documents (`gate-c-report.md`, `dogfood-checkpoint.md` and two
qualification logs), and their trees are byte-identical for `src`, `app`, `scripts`, `static`,
`test`, `package.yaml`, `stack.yaml.lock`, `Dockerfile` and the `lockstep` launcher (equal Git tree
and blob hashes). The installed binary is not the binary the tests ran: the pane built it from
`b963527` on the owner's Mac, and the tests built their own from `bd94c96` in the dev container;
byte-identical builds are not claimed. The remediation code (`C-C.R1`, after `7839c21`) is newer
than both and has **not** been installed or dogfooded.

## What to record

Fill the Result column with PASSED, FAILED (what it said) or NOT_RUN, and note anything that was
confusing, even when the step passed. This is not Gate C acceptance; its results feed C1–C4 in
`docs/gates/C/gate-c-report.md`.
