# Real-novice usability test — predefined procedure (Gate C scenario C9)

- Status: **NOT_RUN** (prepared 2026-10-26 by the writing agent, manual). No participant has
  taken part. Nothing below is a result.
- Authority: Phase 3 handoff P3.10 and P3.11 (C9 "Real first-time participants complete predefined
  journeys"); PRD v0.3 FR-UX-10 ("a successful automated Chromium run is not evidence that a real
  novice succeeded. Record assistance, confusion, incomplete trials and reasons; no simulation of
  human studies"), NFR-15.
- Who runs it: the owner, or a facilitator the owner chooses. The writing agent cannot run it and
  must not fill in results.

## 1. Participants

- At least **3** people, ideally 5, who have never used Lockstep.
- None of them uses Git, Docker, PostgreSQL or a terminal in their work or hobbies (ask: "Have you
  ever typed commands into a terminal or used Git?"; a yes excludes them from the novice group;
  record them separately if they still take part).
- Adults who agree to take part; no payment is required by this procedure. Record only a
  participant number, never a name.

## 2. Set-up (by the facilitator, before the participant arrives)

1. On a Mac with Lockstep installed at the version under test, run `./lockstep` once so the
   service is ready, then stop it with `lockstep stop` (so the participant sees a cold start).
2. Remove any test projects from a previous session, or use a fresh installation.
3. Open a terminal window in the Lockstep folder with `./lockstep` typed but **not** run.
   (Starting Lockstep is the one terminal step in the product; DR-P3.1 decision R.)
4. Have this sheet and a timer ready. Screen recording only with the participant's consent.

## 3. What the facilitator says

Read aloud, exactly:

> "This is a tool for organizing projects and the work in them. I didn't design it, so you
> can't hurt my feelings. I'll give you a few things to do. Please think aloud as you go. I can't
> help you while you work; if you're stuck, say so, and you can choose to skip a task."

During tasks the facilitator may only say: "What are you looking for?", "What do you expect to
happen?", "Take your time.", and, after 3 minutes stuck, "Would you like to skip this one?".
Anything else counts as **assistance** and must be recorded.

## 4. The journeys

Give each task on a card. Time each one from reading the card to the participant saying "done"
or skipping.

| # | Card text | Success means |
|---|---|---|
| J1 | "Press Enter in the window that is open to start the program, and open it in the browser." | the participant reaches Home in the browser (C1) |
| J2 | "Create a project for planning a birthday party. Lockstep can choose where its files go." | a project exists with that purpose, its folder connected |
| J3 | "Add two things that need doing for the party. One of them can only start after the other. Make the first one the most important." | two tasks, one depending on the other, priorities set |
| J4 | "Mark the first task as ready to work on. Then find out which task Lockstep thinks is the most important one ready to work on." | the participant says the right task name |
| J5 | "Something came up: the second task cannot happen this week. Record that, with the reason." | the second task is blocked with a reason |
| J6 | "Find out what checks this project's work must pass, and choose the recommended starting option." | Always-on rules only saved |
| J7 | "Is there anything Lockstep needs you to decide right now? And what has happened so far?" | the participant reports "nothing to decide" and "nothing has happened yet" from the pages |
| J8 | "Close the browser tab. Open Lockstep again and check your party project is still there." | the project and tasks are found again (C2) |

## 5. What to record, per participant and journey

| Field | Values |
|---|---|
| Outcome | COMPLETED, COMPLETED_WITH_ASSISTANCE, SKIPPED, FAILED (wrong result believed correct) |
| Time | minutes:seconds |
| Assistance | exactly what was said or done, or "none" |
| Confusion | words or places that made the participant hesitate, in their words |
| Errors | anything that went wrong on screen, with the exact message |

After all journeys, ask and record verbatim: "What was the hardest part?", "Was any word unclear?",
"Would you use this to organize something real?".

## 6. Reading the results

- C9 is PASSED only if every novice participant COMPLETED J1–J8 without assistance, or the owner
  accepts named exceptions in writing. Any FAILED (a wrong result the participant believed) is a
  finding to fix before Gate C acceptance, whatever the other numbers say.
- Results are recorded only from real sessions, in `usability-results.md` next to this file,
  with the date, the version under test (commit), and the facilitator's name or role.

## 7. Results

| Participant | J1 | J2 | J3 | J4 | J5 | J6 | J7 | J8 |
|---|---|---|---|---|---|---|---|---|
| (none yet) | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
