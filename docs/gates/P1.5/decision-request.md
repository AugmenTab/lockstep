# P1.5 — decision request: a defect in a frozen test

- Prepared by: the writing agent (Implementer), 2026-10-17. As prepared, nothing here was
  decided. **Decided by the human owner on 2026-10-18; see "Human decisions" at the end.**
- State: `v2` at `71b6be0` (P1.5 implementation `7eb31b1`, committed as RED WIP, plus an
  implementation fix `71b6be0` found during this investigation). P1.1/P1.2 ACCEPTED;
  P1.3 and P1.4 `VERIFIED — awaiting human acceptance`.
- Rule that applies: Phase 1 handoff, "Stop, recovery and escalation": stop when "a protected
  test must be changed … propose the smallest recovery, and request the human's decision".
  The writing agent may not edit a frozen test (recovery plan §7.1 precedent, C-P1.2-R1).

## What failed

`scripts/check --integration` at the implementation (`evidence/check-working-tree-red.log`):
format, lint, build and **230/230 unit tests pass**; **8 of 58 integration tests fail**. All
eight are in the frozen `test/integration/Lockstep/DispatcherTest.hs` (C-P1.5 §8, sha256
`b34935aa…`), and all eight fail the same way, before any dispatcher behaviour is checked:

```
Exception: HttpExceptionRequest … path = "/api/health_check" … ConnectionFailure
  Network.Socket.connect: … (Connection refused)
```

## Why it is a test defect

The test's own start-up helper (lines 250–253):

```haskell
healthy :: Int -> IO Bool
healthy port = do
  result <- timeout 1000000 (httpGet port "/api/health_check")
  pure (fmap fst result == Just 204)
```

is polled right after `createProcess`. Until `serve` has bound its port, `httpGet` **throws**
`ConnectionFailure` instead of returning, and `healthy` does not catch it, so the poll loop
ends on the first attempt. A process cannot bind its port before the parent's next
instruction, so **no implementation can make these tests pass**. The frozen P1.2 helper
`Support/Process.waitReady` catches the same exception (`try … HttpException`); the P1.5
helper does not.

Cause on my side: before freezing I compiled the suite and ran the unit baseline, but did not
**run** the integration suite against the current binary. That run would have shown this
failure in start-up code, separate from the expected missing-feature failures (handoff rule 5).

## A second defect in the same file, found by the scratch runs

With only the `healthy` fix applied, a scratch run showed two more failures
(`evidence/scratch-run-1-…`):

- **SIGTERM test — my implementation bug, fixed in `71b6be0`.** The dispatcher was signalled
  only after Warp's graceful shutdown, which waits up to 3 s for idle keep-alive connections, so
  the job finished instead of returning to the queue. The SIGTERM handler now signals the
  dispatcher first. No test changed.
- **SIGKILL test — test-side connection exhaustion.** It failed with PostgreSQL `FATAL: sorry,
  too many clients already` (`evidence/scratch-run-2-…`, deterministic). The frozen
  `Support/Postgres` query helpers open a new connection pool per query and never close it
  (connections linger ≥ 1 s), and this test's `jobState` makes **four** queries per 100 ms poll.
  The SIGKILL case polls longest (it waits for the ≈5 s lease), so it exceeds the server's
  100 connections. The server process holds at most one pooled connection.

## Proposed smallest recovery (for the owner to authorize by its exact diff)

**R-P1.5-1:** amend `test/integration/Lockstep/DispatcherTest.hs` with exactly
`evidence/proposed-test-fix.diff` (+19 −8 lines):

1. `healthy` catches `HttpException` and returns "not ready yet";
2. `jobState` reads the state with **one** query instead of four.

No assertion, timing or scenario changes. Then re-freeze the file with a new digest in C-P1.5
§9 and continue P1.5 verification.

Evidence the fix is sufficient: scratch clone of `71b6be0` with only that diff applied (not
committed): **230/230 unit, 58/58 integration, twice** (`evidence/scratch-run-3-…`,
`evidence/scratch-run-4-…`).

Alternatives: (b) also fix the frozen P1.2 helper `Support/Postgres` to reuse or close its
pools. That is the deeper cause, but it changes an accepted P1.2 frozen file, so it is not
proposed now. (c) Replace `healthy` with the frozen `Support/Process.waitReady`. Same effect as
part 1, larger diff.

## Second item: one deviation to ratify or reject

C-P1.5 E7 says "`/operator` gains a queue form". The frozen P1.4 test (`OperatorCommandTest`,
`fieldValue`) requires **exactly one** `idempotency_key` and one `expected_revision` input on
`/operator`; a second form there would break it. The implementation serves the queue form at
`GET /operator/jobs/new`, linked from `/operator`. No test is affected. Ratify, or direct
another placement.

## Third item: a contract detail to ratify

C-P1.5 E4 says the lease is `now() + 5 s`; the implementation uses `now() + (step_millis + 5000) ms`,
so a step of up to 5 s (allowed by E1) cannot lose its own lease mid-step. No test depends on
the difference. Ratify, or direct exactly 5 s.


## Answer needed

For example: "R-P1.5-1 approved; queue-form placement and lease ratified." Until then P1.5 stays RED
and P1.6/P1.7 do not start.

## Human decisions (2026-10-18)

Decided by the human owner. Recorded by the writing agent (Implementer) at the owner's
instruction; these are the owner's decisions, not the agent's. Owner's words, verbatim:

> **R-P1.5-1 APPROVED**, conditional on the actual `proposed-test-fix.diff` modifying only the `healthy` and `jobState` test helpers as documented. No test assertions, timing expectations, or scenarios may change. Record the authorized amendment, re-freeze the corrected test, and run the full verification suite.
>
> **Queue-form placement RATIFIED.** Keep the form at `/operator/jobs/new`, linked from `/operator`. Update the Contract to reflect this decision.
>
> **Dispatcher lease RATIFIED.** The `step_millis + 5000` millisecond lease is accepted for the model-free no-op dispatcher only. This does not approve general external-effect replay or preempt DG-04.
>
> Record the test helper's connection-pool churn as a known issue. Do not expand this recovery into a refactor of already accepted P1.2 tests unless it becomes necessary for correctness.

Condition check (by the writing agent, before applying): the diff (sha256 `d30e9d76…`) has four
hunks: two import lines used only by `healthy` (`try`, `Network.HTTP.Client.HttpException`), the
body of `healthy`, and the body of `jobState`. No assertion, timing value, poll limit or scenario
changes. Base blob `c1ccda9` = the frozen file (sha256 `b34935aa…`). The new `jobState` maps
states outside `queued`/`running`/`succeeded` to `failed`; the `lockstep_jobs.state` CHECK
constraint allows only those four, so the reported state is unchanged. Applied and re-frozen in
C-P1.5 §9.
