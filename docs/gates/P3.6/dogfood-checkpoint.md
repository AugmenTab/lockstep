# Early value checkpoint — dogfood after P3.5–P3.6 (for the owner)

- Status: **NOT_RUN — owner-only** (prepared 2026-10-26 by the writing agent, manual)
- Authority: Plan v0.3 §2.1 "Early value checkpoint: As soon as P3.5–P3.6 are green, run a real
  browser dogfood that launches Lockstep, registers one existing repository, and creates one
  source-linked task. It is not Gate C-UX acceptance or agent execution."
- Why it is not run by the agent: it uses the owner's own installation, home folder and default
  browser (`./lockstep` with the real browser is owner-only), and it upgrades the operator's
  installation (currently `6c2851d`, schema 5) to the Phase 3 build through the control pane.

## What it needs

- `phase-3` at or after `3adc064` checked out in `~/personal/lockstep`, with no uncommitted
  changes (the pane refuses to prepare an upgrade from a dirty checkout, C-P3.3).
- Docker running (OrbStack).
- An existing Git folder of your own under your home folder to register, e.g. a small personal
  repository. Lockstep only reads it: it is mounted read-only and nothing is pushed.

## Steps (about 15 minutes; the build takes most of it)

1. In a terminal, from `~/personal/lockstep`: `./lockstep`. The control pane opens in the browser.
2. **Version** section: **Prepare an update** → wait → **Review and upgrade…** → **Upgrade now**.
   The pane backs up the database, checks the backup, upgrades it (schema 5 → 14) and starts the
   new version. Expected: "Done: Lockstep was upgraded."
3. **Project folders** section: the first line is `~/lockstep-projects` (made by the helper).
   Type the full path of your existing Git folder → **Review…** → **Add folder**. Expected:
   "Done: Lockstep can now see …" and the service restarted.
4. **Open Lockstep** → Home → **Projects** → **New project**: a name, what it should achieve,
   **In a folder that is already on this computer** → choose your folder → **Create project**.
   Expected: "Lockstep can see this folder: …" and "It cannot change it or run anything in it yet".
5. On the project page: **New task** → what needs doing, what done looks like, priority →
   **Add task** → **Mark as ready to work on**. Expected: "Ready to work on." and on the project
   page "Most important task ready to work on: …".
6. Optional: `lockstep stop` in the terminal, then `./lockstep` again → **Open Lockstep** → the
   project and task are still there with the same words.

## What to record

Record each step as PASSED, FAILED (what it said) or NOT_RUN, together with anything that was
confusing. Add the record below this line or in a new file next to it. A failure here does not
touch the repository you registered. Lockstep made no change to it; check with `git status` in it.
