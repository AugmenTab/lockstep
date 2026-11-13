# Completion packet: post-Phase-5 operational stabilization (S1–S4)

- **For:** the owner. **Prepared:** 2026-11-13 by the Implementer, unattended (owner asleep), on branch
  `stabilization-1`. **The Implementer does not accept this milestone.** Nothing pushed or merged.
- **Handoff:** `.local/plans/phase-05_update4.md` (sha256 `622eb5d5…`). Contract: `contract.md` (this directory).

## 1. Revisions

| | |
|---|---|
| Baseline | `62f353a` (Phase 5 `0bd82b2` + Gate VM-1 records) |
| S1 | `3196dd1` native sign-in renewal diagnostics |
| S2 | `05f1762` reproduction and retry semantics |
| S3 | `731eed5` Planner test conventions; whole-change review |
| S4 | `f05285c` attended-session continuity |
| Review fixes | `3d2f1c3`; record `docs/reviews/stabilization-1-review.md` |
| Final | the head of `stabilization-1` (this packet's commit, docs only on top of `3d2f1c3`) |

## 2. S1: the authentication root cause, and its evidence

**Cause (established, not inferred):** the pinned CLI 2.1.312 renews an expired subscription access token by POSTing a
refresh grant to its OAuth `TOKEN_URL`, `https://platform.claude.com/v1/oauth/token` (read from the pinned binary's
production OAuth configuration and its refresh routine; no credential read). Your `provider/egress-hosts` allows
only `api.anthropic.com`, so the passthrough filter refuses `CONNECT platform.claude.com:443`; the CLI then sends the
expired token and the Messages API answers 401. `claude auth status` reports `loggedIn` from a token being *stored*
(its own status code), so the preflight could not see it.

**Reproduced model-free** (`scripts/lib/check-live-renewal`, 41/41; RED on the old filter image for the
diagnostics, GREEN after): the real pinned CLI, a synthetic sign-in whose access token expired an hour earlier, the
real helper and filter, a TLS stand-in for both hosts on an internal network.
- Renewal host blocked (your current configuration): the filter refused `platform.claude.com:443` four times and
  nothing else; the CLI sent the expired token; exit 1, `api_error_status` 401 — the Brigid failure.
- Renewal host allowed: the CLI renewed once by itself, used only the new token, the run completed, the renewed
  sign-in was kept in the auth volume, and the next role session used it without renewing again.

Not proven: that Brigid's six unrecorded refusals were all `platform.claude.com` (consistent, not recorded then), and
real-provider renewal (§11).

## 3. Provider endpoint identified as necessary — your decision (S1-SD1)

`platform.claude.com` (exact host, port 443): the CLI's own OAuth token endpoint. To allow it, one line in your
helper state's `provider/egress-hosts`, then restart the helper. Details, exposure and the alternative:
`docs/architecture/provider-auth-renewal.md` §4. **Not applied by the Implementer.** Until you decide, an expired
token fails at once with `provider-auth-rejected`, the refused renewal host in the signed result and the helper log,
and one action on the page (sign in again, then *Try this step again*). `claude setup-token` evaluated, not adopted.

## 4. Credential isolation and native authentication preserved

- No token is read, injected or stored by Lockstep; the CLI keeps its sign-in in the auth volume, readable only by
  the CLI identity. Synthetic tokens appeared in no kept file (results, work, helper log, ledger, evidence: C checks).
- No API key or token in the role container's environment (`check-live-renewal` C; `check-live-native` N6, 23/23).
- The filter's records hold only host, port, reason, run, time and method — never a header, cookie, body, path, query
  or user information (R checks with secrets in every part of the requests). Allowlist, exact-host matching and
  end-to-end TLS unchanged; a refused host stays refused.
- No credential enters a Dev Capsule (unchanged; capsule roles run no tools in the role container).

## 5. S2: reproduction and retry, before and after

| | Before | After |
|---|---|---|
| No reproduction command | halted `reproduction-missing`; a person had to accept non-reproduction | recorded as not reproduced (`command` null, `reproduced` false), on to the candidate tests (`reproduction-omitted`) |
| RED baseline | required | **still required**, unchanged: only `red-confirmed` passes; wrong reason, unexpectedly passing and GREEN-only go back, then `candidates-exhausted` |
| A command that does not reproduce | halt; choices accept, **retry** (the same command again), stop | halt; choices accept, **replan** (the Planner's discovery runs again), stop |
| `protected-test-changed` at verify | retry (re-verifies the same commit) | stop only |
| A retry's meaning | "Try this step again" | the question and page say what runs again (e.g. "Retry runs the Planner's search for the cause again") |

Frozen tests amended under the handoff's authority (A-STAB-1 `EngineTest`, A-STAB-2 `EngineHumanTest`; 5 lines,
digests in `amendment-digests.txt`); DG-06 D-6.6 superseded in part (decision register). Halt classes:
`retry-model.md`.

## 6. S3: Planner and Reviewer requirements

- **Planner (candidate tests):** learn the project's test framework, organization, registration, fixtures and naming
  and read the nearest tests; extend the real suite (a whole-file `content` with the new tests added), never a
  standalone runner; test the behavior (several inputs, boundaries, properties where used, positive and negative,
  public interfaces); ask whether a special-cased fix would pass; proportionate, no padding; with no reproduction
  command the RED tests are the proof.
- **Reviewer:** the context lists every file the change touches (basis to candidate, tests included); read them all;
  list what was read (`inspected`); never list an unread file; approve only after reading everything.
- **Supervisor:** an approval that misses a changed file, names a file that is not there, or (a provider-backed
  Reviewer) declares nothing, is recorded as `needs-human` with the gap named and halts; it is never an approval and
  nothing is accepted. A *retry* runs the Reviewer again. Freeze integrity is still the Supervisor's byte check.
- **Qualification:** `ReviewScopeTest` (unit), `StabilizationReviewTest` (5 cases through the whole pipeline). No
  provider tokens spent. The accepted Brigid work was not touched.

## 7. S4: session continuity

The engine, its worker, transactions and decision requests never read operator sessions (by construction), so a
long-running transaction continues through a browser-session expiry, and pending decisions stay pending. Now, when
the app's sign-in ends, the page says so ("nothing was decided for you, and every decision waiting for you is still
waiting") and remembers the page; the next sign-in in that browser returns there once (only an address the app
routes; a foreign one is ignored). Session lifetime (12 h), revocation, origin and CSRF protections unchanged.
`StabilizationSessionTest` (real browser, service, PostgreSQL).

## 8. Test results

| Check | Result |
|---|---|
| `scripts/check --integration` at `f05285c` (S1–S4), clean tree | all 6 steps PASSED: unit 887/887, integration 583/583, backup/restore |
| After the review fixes: unit; targeted integration (C-P4.6, 4.10-14, 4.15, 4.16, S2, S3) | 887/887; 42/42 |
| Final `scripts/check --integration` at `3d2f1c3` (all code; only this packet uncommitted) | all 6 steps PASSED: unit 887/887, integration 583/583, backup/restore |
| `check-live-renewal` (new) | 41/41 (RED first: 9 failures on the old image) |
| `check-refused-hosts` (new, host bash 3.2) | 8/8 |
| `check-live-native` (frozen) | 23/23 |
| `check-capsule-runner` (P5.5–P5.7, real Lima VMs, after the review fixes) | 91/91 |
| Not rerun | `check-capsule-vm`, `-recovery`, `-lan`, `-e2e`: no code they exercise changed (the capsule runtime, template, preflight's VM and LAN sections) |
| New S2 integration cases | RED first (5 of 6 failed on the contradiction), then GREEN |

## 9. Independent review

`docs/reviews/stabilization-1-review.md`: no HIGH; the MEDIUM (a known-impossible retry still offered at
`protected-test-changed`) and the LOW–MEDIUM (the renewal host could be crowded out of the result field) are fixed,
with tests; three more LOWs fixed; three accepted with reasons.

## 10. Remaining operator interventions

Of the Brigid run's avoidable interventions:

| Brigid # | What | Now |
|---|---|---|
| 4 | provider re-login after an expired token | avoidable once S1-SD1 is applied; until then, one named request (sign in again) instead of an opaque crash |
| 5 | app sign-in expired mid-run | still re-sign-in after 12 h, but you return to the same page and nothing is lost |
| 6 | an ineffective retry at the reproduction stop | gone (no such retry is offered) |
| 7 | accepting non-reproduction because no command was given | gone (proceeds to the tests automatically) |
| 3 | setup errors by the Implementer | not a product change |

Still yours by design: initial authorization, security decisions, *Human Done*, and halts that need judgment
(findings, reviews, exhausted budgets).

## 11. Known limitations and security decisions

- **S1-SD1 open** (§3). Real-provider renewal through the filter is **not tested**: it needs your attended,
  authorized run (one short Planner run after the access token has lapsed, with S1-SD1 applied).
- No remote sign-in validation in preflight: the only remote check is provider traffic, which this handoff does not
  authorize.
- The scripted (test-double) Reviewer is exempt from declaring its scope, by adapter name; production builds only
  provider adapters. A typed flag would be better (review finding 6).
- A review's scope is what the Reviewer *says* it read; Lockstep checks the claim against the change and the tree,
  not the reads themselves.
- `changeScope` ignores gitlinks (snapshots carry none). The image tag is repeated in `capsule-preflight`.
- Carried over: the LAN exception is attended-only and expires 2026-11-13T23:00Z; no host-enforced LAN boundary; the
  VM image is not pinned by digest; two capsules at once and a host reboot mid-run not qualified.

## 12. Readiness for ordinary supervised engineering work

Ready, with S1-SD1 decided either way. With it applied, a supervised transaction no longer stops for a lapsed sign-in,
a missing reproduction command or an ineffective retry, and a weak review cannot pass as an approval.

## 13. Remaining prerequisites for unrestricted unattended execution

1. S1-SD1 applied and the attended real-provider renewal test passed.
2. A host-enforced network boundary for the Dev Capsules (the LAN exception is attended-only).
3. Concurrency and restart qualification of capsules (two at once; host reboot mid-run).
4. A pinned VM image.
5. Phase 6 scheduling (out of scope here).
