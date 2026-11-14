# S1-SD1: allow the OAuth renewal host — decision and qualification record

- **Handoff:** `.local/plans/phase-05_update5.md` (sha256 `c008d4c4…`), given by the owner on 2026-11-14 with "Read …
  and implement". Register entry: `docs/governance/DECISION_REGISTER.md`, "Stabilization S1–S4 and S1-SD1".
- **Prepared by** the Implementer, 2026-11-14. Branch `stabilization-1`. Nothing pushed.

## 1. Decision

| | |
|---|---|
| S1–S4 implementation and offline qualification | **Accepted** (the handoff's Planner disposition) |
| S1-SD1, allow `platform.claude.com` | **Approved**; applied 2026-11-14T02:41Z |
| Real-provider renewal | **Not tested; not yet authorized** (§4) |

Nothing beyond the one host changed: no wildcard, no unrestricted egress, no API-key billing, no credential
substitution. Native Claude Code subscription sign-in stays as it was (the CLI's own login in the auth volume,
readable only by the CLI identity), and the filter still relays TLS end to end without terminating it.

## 2. Active allowlist

The owner's helper state is `.local/control` (the `./lockstep` default). Its `provider/egress-hosts` now holds exactly
two lines (46 bytes, checked with `od -c`):

```
api.anthropic.com
platform.claude.com
```

Applied by appending the one line, as `docs/architecture/provider-auth-renewal.md` §4 says. The helper was running
with `--runner`, started by hand (pid 59836, 2026-11-12). `./lockstep stop` and `./lockstep` would have brought it back
without `--runner`. So it was restarted under its own lifecycle instead: SIGTERM (the helper logged `stopped`), then
the same command line, detached as `./lockstep` does. The channel keys were left in place, so the open control pane
keeps working. The restarted helper's log:

```
2026-11-14T02:41:06Z native renewal: the CLI may renew an expired access token at platform.claude.com (allowed in egress-hosts)
2026-11-14T02:41:06Z live runs on: claude-code claude-sonnet-5-5 medium, subscription, native (usage in tokens), at most 16000 output tokens a request (image sha256:78fc11e12b84…)
2026-11-14T02:41:08Z capsule mode on: capsule brigid1, project brigid, verification brigidv, command limit 7200s
2026-11-14T02:41:08Z started (pid 90993, protocol 1, timeout 90s, runner image sha256:1c240898aefd…)
```

The restart also put the stabilization helper and provider image into service. The provider image is the S1
rebuild, `78fc11e1…`, which includes the refusal diagnostics; before the restart it was `4a050cb4…`.

**Not changed:** the installed Lockstep service. It still runs the build installed before stabilization, so S2–S4
take effect only after the usual `scripts/service install`. The helper's new result field, `egress.refused`, is
ignored by an older service, because the runner protocol is lenient about extra fields.

## 3. Qualification (offline; no provider contacted)

**Allowlist** — `scripts/lib/probe-egress-allowlist`: 21/21
(`evidence/allowlist-probe-20261114.txt`, raw answers in `evidence/allowlist-probe-responses.txt`).

The probe builds `--allow` from the live file the same way the helper does (the helper's `read_egress_hosts`, copied
verbatim). It runs the real filter from the pinned provider image on an internal Docker network with no route out.
No auth volume is mounted, and no credential is read.
- **Admitted:** `api.anthropic.com:443` and `platform.claude.com:443`. Both end `upstream-unreachable`: the filter
  admitted them, and the connection then had nowhere to go.
- **Refused `host-refused`:**
  - other Anthropic hosts: `claude.com`, `claude.ai`, `anthropic.com`, `console.anthropic.com`,
    `statsig.anthropic.com`;
  - lookalike names: `evil.platform.claude.com`, `platform.claude.com.example.net`, `xplatform.claude.com`;
  - the right name in another form or on another port: `PLATFORM.CLAUDE.COM`, the trailing-dot
    `platform.claude.com.`, ports 80 and 8443;
  - an unrelated host and a raw IP: `example.com`, an IP literal.
- **Refused `method-refused`:** plain GET and POST to the renewal URL.
- The filter's summary names exactly the two hosts, and it opened no tunnel.

**Synthetic renewal regression** — `scripts/lib/check-live-renewal`, retained from S1:
- `evidence/live-renewal-red-20261113t045814z.txt` is the RED run on the old filter image: 9 failures, all of
  them diagnostics.
- `evidence/live-renewal-green-20261113t063611z.txt` and `…-helper.log` are the final GREEN run, 41/41, from
  after the review fixes.

What GREEN shows:
- **X — blocked (the pre-SD1 configuration):** the Brigid 401, named `provider-auth-rejected`, with the refused
  renewal host in the result and in the log.
- **N — allowed (the configuration now active):** the CLI renewed once at the token endpoint and used only the
  renewed token. The renewed sign-in stayed in the auth volume, and the next session used it without renewing.

**Not rerun today:** `check-live-renewal`. Neither the code nor the image has changed since the GREEN run; the image
digest is the same `78fc11e1…`.

## 4. Real-provider renewal: not validated

**Accepted:** offline qualification (§3). It shows the filter admits the renewal host, and that the pinned CLI
renews itself through the filter against a stand-in that answers as the token endpoint would.

**Not established:** that Anthropic's real token endpoint accepts this renewal through the filter. The handoff
allows the check only "when separately authorized", and it has not been authorized. No real-provider traffic was
sent for this record.

Proposed attended check, for when it is authorized:
1. Wait until the stored access token has expired. Ordinary disuse is enough; the credential is never read,
   extracted or edited to force it.
2. Run one short read-only role through the helper (one Planner run).
3. Confirm all of these:
   - the run did not end `provider-auth-rejected`;
   - the run's `.refusals` file is absent or empty;
   - the summary's `hosts` line is `api.anthropic.com,platform.claude.com`. A tunnel to the renewal host is the
     renewal event itself, visible without touching the credential. A session that only ever reaches
     `api.anthropic.com` proves nothing about renewal;
   - a second role run then completes without contacting `platform.claude.com` again.
4. Record the result and the hosts here.

## 5. Remaining authentication limitations

- Real-provider renewal is unproven until the check in §4 is run.
- If the refresh token itself is revoked or expires, the owner must sign in again (`--provider-auth-login`). Such a
  run fails with `provider-auth-rejected` and one instruction: sign in again, then retry.
- Preflight still checks only that a sign-in is stored; it cannot tell whether that sign-in still works. A remote
  check would itself be provider traffic.
- The allowlist must change if a future pinned CLI moves its token endpoint. `check-live-renewal` V reads
  `TOKEN_URL` from the pinned binary and would fail first.
- Carried over: the LAN exception expired at 2026-11-13T23:00Z and was not extended. Capsule preflight refuses until
  the owner writes a new one for an attended run.

## 6. Installation of the accepted revision (2026-11-14, on the owner's instruction)

"Install the accepted stabilization revision, verify the service and helper, and preserve all existing work."

**Before.** Installed `0bd82b2`, schema revision 21, nothing pending. Both transactions were `done`: calculator
`cf0f209`, and Brigid `73b0203`. There were no open human requests and no queued or running jobs, so nothing was in
flight.

**Steps.** The same steps as the helper's own upgrade (`apply_action`). It was run by hand, because the helper only
acts on requests signed in the control pane.
1. Backed up the database with `scripts/db backup`: `.local/backups/20261114T025724Z-r21-44416.dump`. Verified it as
   the helper does: the digest matches (`5ffdb4a5…`) and `pg_restore --list` reads back 293 entries.
2. Built the candidate into `.local/staging-install` with `scripts/service install` (commit `d00e26c`, clean tree,
   sha256 `4009d6d2…`). It reports `ready 21, pending 0` against the live database.
3. Moved the older rollback slot (`6c2851d`, 2026-10-19) to `.local/install.archive-6c2851d` rather than deleting
   it.
4. Stopped the service; its log is in `.local/install.previous/last-run.log`. Ran the candidate's `db migrate`
   with the verified backup: "nothing to apply".
5. Moved the old install (`0bd82b2`) to `.local/install.previous`, the helper's restore slot, and the candidate to
   `.local/install`.
6. Started the service with the helper's `LOCKSTEP_SERVICE_FOLDERS` and `LOCKSTEP_SERVICE_RUNNER`, as the helper
   would.

**Verified after.**

The service:
- It runs `d00e26c`.
- The health check answers 204, and `db status` reports `ready 21, pending 0`.
- Startup: "Engine worker: on (live provider claude-code, model claude-sonnet-5-5, effort medium, tools in Dev
  Capsule brigid1)".
- Its environment, mounts and user are identical to the previous container's: the project folders, and the runner
  directory read-write.

The new build is the one serving:
- The served `/static/app.js` is byte-identical to the S4 tree.
- The binary contains `reproduction-omitted`, `provider-auth-rejected` and "Retry runs the Planner".

The data:
- Row counts are identical before and after for transactions (2), transaction records (82), events (8),
  invocations (27), work orders (2), tickets (3), projects (3), human requests (5), conversation messages (10) and
  operator sessions (20).
- Both accepted commits are unchanged.

The helper:
- pid 90993 is still running with `--runner`, and the runner channel is in place.
- Capsule status: `brigid1` Running, audit ok, template current, nothing under way.

`scripts/capsule-preflight` against the live state: every check passes, including the new
`provider-renewal-path`, except `lan-exception` (expired) and `host-network-exposure` (which needs that exception).
Those two are expected and were not touched.

**Rollback.** By hand. The control pane offers *Restore previous* only after a failed upgrade, which this was not.
1. Stop the service.
2. Move `.local/install.previous` back to `.local/install`.
3. Start the service with the same two variables.

No schema changed, so the database needs no restore. The backup above is kept regardless.
