# Human-operated demonstration (AC-A1-18@v2) — record

- Date: 2026-10-18, about 20:00–20:12 UTC. Report r2 (`gate-report.md`, sha256 `33c8d26a…`),
  tested commit `6c2851d` (installed binary, `.local/install/VERSION`, `dirty false`), service on
  `127.0.0.1:8010` against the operator database.
- Recorded by the writing agent (Implementer) from the owner's statements in session, quoted
  verbatim, and from database observations. **This record does not set AC-A1-18's disposition
  and is not an acceptance.** The owner decides both (`decision-packet.md`).

| Step | Who | Owner's statement (verbatim) / observation | Database evidence |
|---|---|---|---|
| 1 Start service | agent, at the owner's request ("run step 1 on port 8010") | clean tree; installed `6c2851d`; schema 5; `ready 5`; only listener `127.0.0.1:8010` | — |
| 2 Status page | owner | (covered by "All confirmed") | — |
| 3 Sign in | owner (link issued by the agent at the owner's request) | — | session created 20:03:35 |
| 4 Rename through the browser form | owner | "step 4 worked, renamed and got applied receipt." | receipt 11: `applied`, actor `browser-session`, revision 2 → 3 |
| 5a Replay (reused key) and stale (CLI) | **agent**, at the owner's request ("Is there any reason you can't run step 5a?") | receipt 12 applied; the identical command returned receipt 12 `(replayed)`; the stale command exited 65 | receipts 12 (`applied`, cli, 3 → 4), 13 (`refused_stale`, cli) |
| 5b Stale through the browser (two tabs) | owner | "Nope, got receipts for both renames." | receipt 14 `applied` (browser, 4 → 5); receipt 15 **`refused_stale`** (browser, expected 4, current 5) |
| 6 Queue a job, close the tab | owner | "Queued." | job 7 (10 × 1000 ms) admitted (receipt 16) |
| 7 Restart | agent, at the owner's request | clean restart on 8010 | job 7 was already `succeeded 10/10, attempts 1` **before** the restart |
| 8 Command center | owner | "All confirmed." | — |
| 9 Sign out | owner | (covered by "All confirmed") | demonstration session revoked 20:11:24 |
| 10 `localhost` refused | owner | (covered by "All confirmed") | not observable server-side (refusals store nothing) |

## Findings raised during the demonstration (for the owner and the Planner)

1. **A stale refusal looks like success (comprehension defect, P1.6 scope).** In step 5b the
   server refused tab B correctly: 409, receipt 15 `refused_stale`, nothing changed. But the 409
   page is the same receipt page as a success ("Receipt 15", with `refused_stale` only in the
   Outcome row), and the owner read both submissions as successful. A refusal must be visibly
   distinct, for example a "Refused: the workspace has changed since this page was loaded (now
   revision 5)" heading with refusal styling. Not changed mid-demonstration (it would change the
   tested commit).
2. **Sign-in usability.** The owner considers the CLI one-time-link sign-in unacceptable as an
   everyday flow (paraphrased; the owner's words were stronger) and will discuss it with the
   Planner. It is the P1.3 design as approved (D-1a/D-2d; 12-hour sessions).
3. **A restart during a running job was not exercised live.** Job 7 had finished before the
   step 7 restart, because the older queued job had already completed. Resume after SIGTERM is
   covered by the frozen `DispatcherTest` and the P1.5 operator run; it can be repeated live with
   a longer job if wanted.
4. Step 5a was run by the agent at the owner's request, so it is not human-operated.

## Housekeeping

- The agent revoked one live session it had left in the operator database (its browser-driver
  smoke test, created 19:10:25). One session from the owner's first, failed demonstration attempt
  (18:54:40) is still live; `scripts/service cli operator sign-out-all` ends it.
- The service is still running on `127.0.0.1:8010`.
