# Proposal — the first real-provider smoke (P4.17), for the owner's authorization

- Status: **PROPOSED — NOT RUN.** Nothing here has been done. No provider was called, no credential exists, the
  live adapter is not built, nothing is installed. Each step below needs the owner's explicit authorization.
- Prepared 2026-10-28 by the writing agent (Implementer, manual) under `.local/plans/phase-04_update2.md` §5.
- What it would show: one real model, through Lockstep's real engine, service, container runner and Git
  boundary, fixing one tiny disposable bug end to end, with a person deciding at every point Lockstep is built
  to stop. What it would not show: general coding ability, cost at scale, or anything about Polygon Pong.

## 1. What has to exist first (each separately authorized; none of it calls a provider)

| # | Piece | Today | Work |
|---|---|---|---|
| B1 | The live Claude adapter (C-P4.5 §3a): writes the role's context, runs Claude Code CLI non-interactively inside the helper's container, the answer only through `result.json` | NOT_BUILT | Code and offline tests (no call); the adapter interface is provider-neutral |
| B2 | The provider-egress proxy (DG-17: the live path only through a restricted proxy, no other route) | NOT_BUILT | A per-run network with only the proxy, allowing only the provider's API host; offline tests |
| B3 | Credential handling (DG-17: per invocation, never logged or persisted) | NOT_BUILT | Read from a 0600 file on the host by the helper, passed to that one container, removed after |
| B4 | The engine on in the operator's installation | Built, off: `lockstep serve` runs the worker only with the helper's runner channel (C-P4.17 Q5) | Start the operator's helper with `--runner` (the launcher does not yet offer it); install the candidate |

## 2. The smoke

| Item | Proposal |
|---|---|
| Repository | A **new, disposable** project made in the browser in a new folder under `~/lockstep-projects` (e.g. "calc smoke"): one file `calc.py` with `def add(a, b): return a - b`, committed by the owner. Not an existing repository, not Polygon Pong. No remote. |
| Bug task | "add subtracts instead of adding" — done looks like: "add(2, 2) is 4 and add(1, 2) is 3". |
| Provider and models | Claude Code CLI (DG-17's first live provider). Proposed: **`claude-sonnet-5-5` for every role** at default effort (cheapest model that is likely to manage a one-line bug; the owner may choose Opus 5.5 for the Implementer). |
| Invocations | The engine's own bounds (DG-06, DG-17): Planner ≤ 4 (discovery + at most 3 candidates), challenger ≤ 5 (3 before the freeze, 2 after), Implementer ≤ 2, Reviewer ≤ 2: **at most 13 role invocations**; the happy path is 6. No person's *Try again* during the smoke: any halt is answered *Stop*. |
| Spend and tokens | Proposed hard caps, enforced by the adapter and checked after each invocation: **US$ 5 in total**, **400 000 tokens in total**, at most 60 000 output tokens per invocation; a cap reached stops the next invocation (the transaction halts for a person, then *Stop*). |
| Wall clock | Per role as DG-17 (Implementer 20 min, others 10 min); **the whole smoke at most 60 minutes** of engine time. |
| Network | Only the proxy, only the provider's API host. Verification runs with `--network none`, as today. |

## 3. What the owner would see (expected workflow)

1. `./lockstep` (helper with `--runner`, installed candidate); in the browser: new project in a new folder,
   **Let Lockstep fix bugs here**, the task, **Mark as ready**, **Ask Lockstep to fix this bug**.
2. The task page's *Fixing it*: the steps in turn — finding the cause, reproducing, writing tests that show
   the bug, checking them, fixing them in place, changing the code, running the checks, looking for flaws,
   review — each with what it must do, how it is checked and what the checks showed.
3. Committed on `lockstep/<work order>` in the project's folder (never `main`, never pushed): **Is this bug
   fixed?** — the owner decides Done or not. Lockstep never decides it.

## 4. Evidence to keep

- The transaction's records and every invocation (argv, runner `container`, outcome, exit, digests and tails,
  the kept answer, C-P4.R1 R-I1); the provider's usage per invocation (tokens, cost) as the adapter records it;
  the helper's runner journal; the Git branch and its commits (authors: the Supervisor only).
- The owner's own observations, written by the owner (never synthesized from browser automation).

## 5. Stop conditions (any one ends the smoke: *Stop* on the halt, no retry)

A halt for any reason; an uncertain invocation; a cap of §2 reached; any network attempt outside the proxy
seen in the helper's journal or the container; any change outside the allowed path or to a protected test
(refused by the Supervisor in any case); any finding `CONFIRMED` after the second attempt; the owner's word.

## 6. Clean-up and reset

*Done* or *Stop* on the page; delete the throwaway project's folder (its branch goes with it); revoke the
credential; `lockstep stop` (the runner's run folders are removed after each finished stage; anything left
under `.local/control/runner/work` is removed by hand only after checking no container runs); the database
records stay as evidence, or the owner restores the backup taken before the smoke.

## 7. Exactly what needs the owner's authorization

1. Building B1–B3 (code and offline tests only; no provider call).
2. Installing that candidate on this Mac and starting the helper with `--runner` (B4).
3. Creating the credential with the spend cap of §2.
4. Running **one** smoke, as in §2–§6, with these caps.
5. Separately, Gate C-EXEC itself (its packet does not depend on this smoke).
