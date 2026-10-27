# Early value checkpoint — dogfood (for the owner)

- Status: **NOT_RUN — owner-only** (prepared 2026-10-26; brought up to date 2026-10-27 after the
  Planner disposition, by the writing agent, manual)
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
| 1 | In the terminal: `./lockstep` | The control pane opens in your default browser and says the installed version | |
| 2 | **Version** → **Prepare an update** → wait → **Review and upgrade…** → **Upgrade now** | The pane backs up the database, checks the backup, upgrades it (schema 5 → 15), starts the new version: "Done: Lockstep was upgraded." | |
| 3 | **Project folders**: the first line is `~/lockstep-projects`. Type the full path of your folder → **Review…** → **Add folder** | "Done: Lockstep can now see …"; the service restarts | |
| 4 | **Open Lockstep** | Lockstep's Home opens in the browser, signed in | |
| 5 | **Projects** → **New project**: a name, what it should achieve, **In a folder that is already on this computer** → your folder → **Create project** | "Lockstep can see this folder: …" and "It cannot change it or run anything in it yet" | |
| 6 | On the project page: **New task** → what needs doing, what done looks like, priority → **Add task** → **Mark as ready to work on** | "Ready to work on."; the project page says "Most important task ready to work on: …" | |
| 7 | On the project page, under **How work is checked**: **See or change how work is checked** → **Always-on rules only** → **Save** | "Saved."; the project page then says "Chosen: Always-on rules only." Nothing runs | |
| 8 | **Decisions** | "Nothing needs your decision right now." (no work has run) | |
| 9 | **Activity** | "Nothing has happened yet." | |
| 10 | Optional: `lockstep stop`, then `./lockstep` → **Open Lockstep** | The project, task and checks are still there with the same words | |
| 11 | In your registered folder: `git status` | The same as before you started: Lockstep changed nothing | |

Nothing in these steps runs an agent or a model, and nothing is pushed anywhere. Running work
inside a project arrives in a later update.

## If something goes wrong

- The upgrade fails in step 2: the pane keeps the previous version and the verified backup, and
  says so (C-P3.3). Record its words; don't retry more than once.
- Any other step fails: record the exact words on the page and the step number. Your registered
  folder is untouched either way.

## What to record

Fill the Result column with PASSED, FAILED (what it said) or NOT_RUN, and note anything that was
confusing, even when the step passed. This is not Gate C acceptance; its results feed C1–C4 in
`docs/gates/C/gate-c-report.md`.
