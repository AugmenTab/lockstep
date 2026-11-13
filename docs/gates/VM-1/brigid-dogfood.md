# Gate VM-1: Brigid live-run packet (P5.12)

- **For:** the owner. **Prepared:** 2026-11-12 by the Implementer, on Lockstep `phase-5` at `0bd82b2` (installed
  and running for the whole run). The Implementer does not accept this gate.
- **Owner's verdict (2026-11-12, in session, given before this packet was written):** "approved. I don't care
  for the way the test was written, but that isn't what we're testing, and it's partially my fault for not having
  examples already."
- **Decision: ACCEPTED** by the owner on 2026-11-13: "Marked it done, and it's confirmed." Human Done was recorded
  at 04:28:32Z (transaction `done`). Register entry: `docs/governance/DECISION_REGISTER.md`, "Gate VM-1".
- **Evidence:** everything cited below is in `evidence/p5.12-brigid/`.

## 1. Result

| Item | Value |
|---|---|
| Ticket | HXML `scrollToInputOffset` serializes to the wrong attribute name (phase-05 §16) |
| Lockstep project | `ab412d95-5690-4033-80b8-730386cb4ad7`, folder `~/lockstep-projects/brigid` (a separate copy; no remote) |
| Basis | `9344bfb` (GitHub `main`; your choice, since `main` had moved on from `331dcc0`) |
| Work branch | `lockstep/c7fd1644-d812-4368-9894-87faf8bc471b` |
| Frozen tests | `cd0c17f` "Lockstep: frozen tests" (only `brigid/test/Spec.hs`, +69) |
| Accepted | `73b0203` "Fix: HXML scrollToInputOffset serializes to the wrong attribute name." (only the two renderers, +2/−2) |
| Final state | `accepted` at 21:45:34Z; **`done`** at 2026-11-13T04:28:32Z (your Done) |
| `main` | unchanged at `9344bfb`; nothing pushed or merged |
| Your checkout | `/Users/tab/personal/brigid` untouched (clean, `main...origin/main`) |

The whole change is `evidence/p5.12-brigid/diff-9344bfb-73b0203.patch`. Both Supervisor commits are authored
`Lockstep Supervisor <supervisor@lockstep.invalid>` (their timestamps are the Supervisor's deterministic ones, not
the wall clock).

## 2. The run, step by step

From `transaction-records.txt` (40 Supervisor records), `invocations.txt` and `helper-log.txt`:

| Time (UTC) | Stage | Capsule | Outcome | Tokens |
|---|---|---|---|---|
| 06:08:42 | handed over; basis checked, branch made | — | — | — |
| 06:08:59 | discovery / Planner | `brigidv` | **role-crashed**: "401 OAuth access token has expired" | 0 |
| 15:45:43 | discovery / Planner (your retry) | `brigidv` | answered: the cause and both renderer files, read-only | 48,470 |
| 15:46:20 | reproduction | — | **stopped `reproduction-missing`**: the Planner gave no command | — |
| before 21:19 | your retry: the same empty command, stopped again | — | — | 0 |
| 21:19 | your **accept non-reproduction** | — | — | — |
| 21:20:25 | candidate / Planner (1st) | `brigidv` | a standalone `test/HXML/ScrollToInputOffsetCheck.hs` | 131,425 |
| 21:23:12 | baseline | `brigidv` | exit 1, classified **red-wrong-reason**; rejected | — |
| 21:24:16 | candidate / Planner (2nd) | `brigidv` | the tests in the existing `test/Spec.hs` | 101,045 |
| 21:27:06 | baseline | `brigidv` | exit 1, classified **red-confirmed** | — |
| 21:27:40 | challenge (pre) | `brigidv` | no findings | 57,690 |
| — | tests frozen at `cd0c17f` | — | — | — |
| 21:37:58 | **implement / Engineer** (write) | **`brigid1`** | answered, exit 0, 612 s | 102,828 |
| 21:41:38, 21:44:30 | verification ×2 | `brigidv` | exit 0 both (`stack … build --fast --test`, Brigid's `scripts/test`) | — |
| 21:45:01 | challenge (post) | `brigidv` | no findings | 61,049 |
| 21:45:32 | review | `brigidv` | **approve** | 39,702 |
| 21:45:34 | accepted `73b0203` | — | — | — |

- **Totals:** 8 role runs (1 failed at login), 542,209 tokens. 4 verification-capsule test runs. Model
  `claude-sonnet-5-5`, effort `medium`, subscription billing.
- **Active engineering time**, from accepting non-reproduction to acceptance: 26 minutes. The rest of the
  15.6 hours from hand-over was waiting for you (the re-login and the reproduction stop).
- **Engineer's run.** In `brigid1`, which had **no Haskell toolchain**, the Engineer installed Stack and the
  `libphonenumber` dev libraries itself, cold-built Brigid, and ran the build and tests. That took 612 s, inside the
  7200 s limit (`role-results-tail.txt`). Its result file shows `capsule brigid1`, `protected-changed 0`.

## 3. Gate VM-1 decision points (phase-05 §16)

1. **An actual VM-backed Dev Capsule.** Every role and test run went through the helper's capsule mode: the write
   run in `brigid1`, everything else in `brigidv` (`helper-log.txt`, each line naming its capsule). Preflight passed
   before (`preflight-and-run-log.txt`) and after (`preflight-after-run.txt`) the run: 0 failures, 17 checks.
2. **A real Haskell codebase.** Brigid's real `scripts/test` (Stack 3.11.1, GHC 9.10.3; packages `brigid` and
   `brigid-generation`) ran in the verification capsule:
   - in the transaction, twice, exit 0;
   - again by the Implementer after acceptance, from the trusted snapshot (§4).
3. **Project toolchain and guest Docker, without host access.**
   - The Engineer set up its own toolchain in `brigid1` without you installing anything, and without a
     permission prompt.
   - Brigid's tests don't use Docker, so guest Docker was not exercised by this ticket. `guest-docker` passed in
     preflight before and after. Docker and Compose in the guest are qualified in P5.4 (D1–D7).
   - The host loopback stays closed (`host-loopback-isolation` PASS); there are no host mounts and no Docker
     socket.
4. **Native provider authentication protected.**
   - `credential-not-in-guest` passed before and after the run.
   - The CLI's login stayed in the `lockstep-provider-auth-main` volume. Lockstep never read it.
   - Egress went only to `api.anthropic.com` (`egress-ledgers.txt`). The one run with refusals (6) is the run that
     failed on the expired login. Every run after the re-login had 0 refusals. That fits the suspicion that the
     expired login was trying to renew through a host the filter blocks (retro).
5. **Execution, test-freeze, Git and human authority survived.**
   - The Engineer changed only the two renderer files (`git diff cd0c17f 73b0203`); `protected-changed 0`.
   - The Supervisor rejected a test candidate that failed for the wrong reason, and stopped twice for a human.
   - Both commits are the Supervisor's, on the work branch. `main` didn't move, there is no remote, and your
     checkout was untouched.
6. **The real defect independently verified and fixed.**
   - RED: the frozen tests failed on the basis, classified `red-confirmed`.
   - GREEN: verification passed twice in `brigidv`, a separate VM restored from `verify` before each run, plus the
     Implementer's rerun (§4).
   - Two independent read-only checks: the post challenge (no findings) and the review (approve).
7. **Reviewable and usable.** The change is 2 renderer lines and 69 test lines. You reviewed the diff in session
   and gave the verdict above.

## 4. The Implementer's independent rerun (after acceptance, model-free)

`evidence/p5.12-brigid/verify-accepted-73b0203.out`. The steps: `restore brigidv verify`; a fresh import of a
bundle of `73b0203`; then `.local/brigid/verify-accepted.sh`, which runs `scripts/test` and keeps the per-suite
summaries and the new tests' lines. This was done because the Supervisor keeps only an output tail, which shows
`brigid-generation` (266 tests) but not the `brigid` suite.

The log is `verify-accepted-73b0203.log`. The run went from 2026-11-13T04:20:38Z to 04:24:36Z, on a fresh tree
at `73b0203`, and exited 0:

```
brigid           >   HXML scrollToInputOffset
brigid           >     text: scroll-to-input-offset name:         OK
brigid           >     bytes: scroll-to-input-offset name:        OK
brigid           >     text: both attributes coexist:             OK
brigid           >     bytes: both attributes coexist:            OK
brigid           > All 474 tests passed (0.01s)
brigid-generation> All 266 tests passed (99.31s)
```

That's 740 tests: the basis's 736, plus the 4 new ones. None of the existing tests were removed or skipped.

## 5. Your interventions (phase-05 §16 categories)

| # | When | What | Category |
|---|---|---|---|
| 1 | before hand-over | "I authorize the live Brigid run" | Initial authorization |
| 2 | before hand-over | Basis `9344bfb` | Necessary decision (GitHub `main` had moved) |
| 3 | before hand-over | Created the project in the app. The Implementer first gave the wrong sign-in page and started the service without its project folders | Avoidable: Implementer's setup errors |
| 4 | before 15:45Z | Logged in to the provider again (`--provider-auth-login`), then retried | Avoidable environment troubleshooting: an expired login that preflight could not see |
| 5 | ~21:03Z | Signed in to the app again (the 12 h session expired at 18:02Z) | Avoidable environment troubleshooting |
| 6 | before 21:19Z | Retried the reproduction stop, on the Implementer's wrong advice; it could not help | Avoidable: Implementer's error |
| 7 | 21:19Z | Accepted non-reproduction | Required by the Supervisor's stop, but avoidable: the role is told the command is optional (retro) |
| 8 | 2026-11-13 04:28Z | Human Done | Final Done |

- **Not needed:** permission prompts (none; the 6 role results whose kept tail includes the field all show
  `permission_denials: []`, and the other 2 tails were cut before it), manual test
  runs, manual dependency installation.
- **The desired result, "no avoidable operational intervention", was not met.** Interventions 3–7 were
  avoidable. None of them touched the code, the tests, or the Engineer's diagnosis.

## 6. Known limitations

1. **No reproduction.** The bug was not reproduced before the tests were written; the RED baseline stands in for
   it.
2. **Test quality.**
   - The first candidate was a standalone single-attribute file. The accepted tests are inline substring checks
     in `Spec.hs`, not a reusable `test/HXML/Render/` module like `test/HTML/Render/`.
   - They use only the value 50; the challenger noted a hard-coded 50 would pass.
   - Not a gate criterion. The candidate role has no guidance to follow a project's test conventions.
3. **The review's own limits.** The Reviewer says it read only the two renderer files, not the whole diff, and
   couldn't check `Spec.hs`'s digest. The Supervisor enforces the freeze itself (`protected-changed 0`, the diff
   above).
4. **Provider login.**
   - `auth login` gives a short-lived token, and renewal may be blocked by the egress filter. If so, a run longer
     than one token's lifetime fails. Recommended: a `setup-token` credential.
   - Preflight can't see an expired login.
   - The filter doesn't record the hosts it refused.
5. **The reproduction stop.** The role prompt calls the reproduction command optional, but the Supervisor stops
   without one, and retrying at that stop can't help.
6. **App session.** It lasts 12 h, shorter than an attended run.
7. **Records.** The `lockstep_invocations.runner` column says `container` for capsule runs; the helper log and
   result files name the capsule. Only output tails are kept.
8. **Carried over** (`qualification.md`, Known limitations): the LAN exception is attended-only and expires
   2026-11-13T23:00Z; there is no host-enforced LAN boundary; the VM image is not pinned by digest. Not
   qualified: two capsules running at once, or a host reboot mid-run.
9. **Separate copy versus your checkout.** You asked the Planner to reconsider the rule (retro).

## 7. Acceptance request

The Implementer asks the owner to record:

- **Human Done** for the Brigid task (task page), and
- **Gate VM-1** acceptance or rejection. You gave "approved" in session before this packet was written; please
  confirm it stands with the limitations above.

Retro notes for the Planner: `.local/retros/retro-05.md`.
