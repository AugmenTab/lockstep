# Contract — P4.17 Gate C-EXEC end-to-end qualification

- Contract ID: `C-P4.17@v1`
- Status: **FROZEN** (§4)
- Authority: Phase 4 handoff P4.17 ("Prove a complete no-plan bug Ticket workflow through the real UI, Git,
  PostgreSQL, role adapters, semantic challenge, independent review, controlled recovery and human decision
  boundary. Require a model-free deterministic suite with scripted role adapters, plus an independently
  authorized, finite real-provider smoke. The deterministic orchestration scenarios must exercise real process
  and Git boundaries. They are not sufficient to claim real model coding capability. A live-provider trial must
  not be silently substituted for a test fixture or conducted without separate owner consent. Exit: Present the
  evidence-backed C-EXEC decision packet to the owner and STOP"); `.local/plans/phase-04_update1.md`
  (model-free role adapters and disposable local repositories; live provider calls, installation, remote
  publishing and the gate's acceptance stay separately authorized; UX-C8/UX-C9 NOT_RUN — DEFERRED BY OWNER).
  `.local/plans/phase-04_update2.md` (sha256 `c3b2a6fd…6278b8`): resume P4.17 after the remediation (C-P4.R1);
  "the operator must have a real, supported means to cause authorized transactions to progress … keep this
  change as narrow as possible"; prepare, do not run, the real-provider smoke.
- Writer: the single writing agent (Implementer, manual).
- Scope: qualification, and one production change (Q5): `lockstep serve` runs the engine worker when the host
  helper's runner channel is there. The real-provider smoke is NOT_RUN: it needs the owner's separate
  authorization, and the live Claude adapter it would use is NOT_BUILT (C-P4.5 §3a); its proposal is
  `real-provider-smoke-proposal.md`.

## 2. Decisions

| # | Decision |
|---|---|
| Q1 | **The deterministic end-to-end scenario** (one test, three browser passes): in headless Chromium against the real `lockstep serve` binary and a migrated real PostgreSQL database, a person makes a project in a new folder, lets Lockstep fix bugs there, writes a bug task with what done looks like, marks it ready and hands it over. The engine worker (C-P4.15 W1) runs **in the test's process** with the scripted roles (C-P4.5 A4) and the direct runner over the same database, against the project's real Git folder, with real processes. The fix stops on the person's uncommitted change (controlled recovery, C-P4.6 E3); the person removes it and answers "Try this step again" on the task page (C-P4.16 U5); the fix is reproduced, its test frozen, the code changed by the Implementer, verified on the exact commit, challenged after the change, reviewed independently and committed by the Supervisor on its own branch; the person sees the checks and the review and marks it fixed on the page (C-P4.16 U6), which stays after a reload. |
| Q2 | **What is checked afterwards**, from the database and Git: one transaction done; one completion and one resume, both by a person; one binding answer `retry` by a person through the application; no invocation left unfinished; `main` unchanged; one work branch whose `calc.py` is fixed and which holds the frozen test, its last commit by the Supervisor; no remote; the folder clean. |
| Q3 | **Why Q1's worker runs in the test's process**: the production binary takes no test seams (C-P1.7 E4 refuses a fault plan), and no coding helper is built into it — the live adapter is NOT_BUILT and separately authorized — so the scripted roles cannot be inside it. Everything the person does is through the real service; everything the engine does is the real engine on real Git and processes. Reported as such in the gate packet, not as more. |
| Q4 | **Not vacuous**: before the freeze the scenario is also run with the worker doing nothing (no pending bug started, no transaction advanced); it must fail at the hand-over pass. |
| Q5 | **The engine in the installed service** (the supported arrangement): `lockstep serve`, once its database is ready, starts the engine worker (C-P4.15 W1, C-P4.R1 R-W1/R-W2) **when `LOCKSTEP_RUNNER_DIR` names the host helper's runner channel** — `scripts/service` passes it when the helper was started with `--runner` — with the container runner (C-P4.2 R3) for every role and command, a pass every 2 s, and a bounded stop (8 s, inside `scripts/service`'s 10 s) at shutdown; it logs `Engine worker: on (…)`. Without a channel (or one that does not open) it logs `Engine worker: off (…)` and starts nothing, so the C-P4.1 "nothing runs yet" lines stay true. No coding helper is built in: a handed-over bug is started, its basis taken and its branch made, then it stops for a person at discovery (`role-failed no-coding-agent`, "No coding helper is set up for Lockstep."); the person's answers and Done are acted on by the service. The live adapter, once authorized, plugs into the same worker. |

## 3. Verification (to be frozen)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EndToEndTest.hs` | integration: real browser, real service binary, real PostgreSQL, real Git and processes; scripted roles, no provider | Q1, Q2 |
| `test/integration/Lockstep/ServeWorkerTest.hs` | integration: the real `lockstep serve` binary with the real host helper's runner channel (a `docker` stand-in), real PostgreSQL, Git, HTTP | Q5 |

## 3a. Not run here (owner's separate authority)

| Item | Status |
|---|---|
| Real-provider smoke (finite, owner-authorized) | NOT_RUN — needs separate authorization; the live Claude adapter is NOT_BUILT; proposal `real-provider-smoke-proposal.md` |
| A coding helper in the installed service | NOT_BUILT — the live adapter; the worker it plugs into is Q5 |
| UX-C8, UX-C9 | NOT_RUN — DEFERRED BY OWNER |

## 4. Freeze record

- Frozen 2026-10-28 by the single writing agent (Implementer, manual), on `phase-4` after `cadd969`, together
  with C-P4.R1 (they share the integration runner).
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EndToEndTest.hs` | `72c98b712dbedbef2bfd8a0903e57a4395bfc80de620db936d77b6be97a61623` |
  | `test/integration/Lockstep/ServeWorkerTest.hs` | `3df922f37317fa7cb2e210f3dd17638bede8f426f9c88b75786460d9b8ec6b76` |
  | `test/integration/Main.hs` (shared with C-P4.R1) | `f1944e1ccea68194f8beb9ef56864f0b00b987c9670b9bee443465a8ca9959ec` |

- Baseline, Q4 and Q5 (the worker's pass doing nothing; `lockstep serve` without the worker): **3 of 3 fail**
  — the journey at the hand-over pass (`asked`, `words` not found), the service starting nothing with the
  channel, and no `Engine worker: off` line without it (`.local/p417-baseline.log`).
- Trial against the implementation: **3 of 3 pass** (`.local/p417-trial.log`): the browser journey in 242 s;
  the service-run worker started the bug, stopped it at discovery for a person and acted on the Stop from the
  page.

## 5. Allowed paths

New: the two test files; `docs/gates/P4.17/**`; `docs/gates/C-EXEC/decision-packet.md`. Changed:
`app/lockstep/Main.hs` (Q5 only), `docs/OPERATOR_GUIDE.md` (how to run the engine), `lockstep.cabal`
(generated), the integration runner (additive), `docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 attempts per failing frozen test. Stop at the gate packet: the gate is the owner's to accept.
