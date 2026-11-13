# Native subscription sign-in: renewal, diagnostics and preflight

Post-Phase-5 stabilization, increment S1 (`.local/plans/phase-05_update4.md` §2). Builds on C-P4.L.N (native
subscription authentication, `docs/gates/P4.L.N/contract.md`), which this does not change.

## 1. What failed in the Brigid run, and why

The first Brigid role run (`discovery/planner`, run `71a6485a…`, 2026-11-12 06:08Z) ended with exit 1 and the CLI
result `"api_error_status":401`, "OAuth access token has expired". The offline `claude auth status` had said
`loggedIn: true`. The passthrough filter refused 6 connections, but it did not record which hosts.

**The cause, established from the pinned CLI and reproduced offline:**

1. The pinned CLI (`@anthropic-ai/claude-code` 2.1.312) renews an expired subscription access token by posting a
   refresh grant to its OAuth `TOKEN_URL`, `https://platform.claude.com/v1/oauth/token`. This was read from the
   pinned binary's own production OAuth configuration (`TOKEN_URL:"https://platform.claude.com/v1/oauth/token"`,
   next to `BASE_API_URL:"https://api.anthropic.com"`), and from the refresh routine that posts `grant_type:
   "refresh_token"` to it. No credential was read to establish this.
2. The role container reaches the internet only through the passthrough filter, and the owner's
   `provider/egress-hosts` allows only `api.anthropic.com`. The renewal `CONNECT platform.claude.com:443` is refused.
3. The CLI then goes on with the expired access token, and the Messages API answers 401.
4. `claude auth status --json` reports `loggedIn` from whether a token is *stored* (the CLI's own status code computes
   it from the token's presence), not from its expiry or the provider's acceptance. So the preflight could not see it.

**Reproduced, model-free** (`scripts/lib/check-live-renewal`, part X): the real pinned CLI, a synthetic sign-in whose
access token expired an hour ago, the real helper and filter, and a stand-in for both provider hosts on an internal
network. With `egress-hosts` = `api.anthropic.com`: the filter refused `platform.claude.com:443` 4 times, the CLI
sent the expired token, the run exited 1 with `api_error_status` 401 — the Brigid failure exactly.

**What is not proven:** that the 6 refusals of the Brigid run were all `platform.claude.com` (the filter did not
record hosts then; it does now), and that the real provider's renewal works through the filter. The latter needs an
authorized, attended provider test (§5).

## 2. Diagnostics (handoff §2.2)

The passthrough filter now records each refused request, and only this:

- `DIR/provider/ledger/runs/RUN.refusals`: one line per refusal, at most 64 per run:
  `refused UNIX RUN HOST PORT REASON METHOD`.
- The run's summary gains `refused-hosts HOST:PORT:REASON,...` (at most 16 distinct); its other lines are unchanged,
  and every refusal is still counted in `refused N`.
- For `CONNECT` the host and port are the request's `host:port`. For a plain proxied request, only the URL's
  authority is read (user information dropped, nothing after the authority); for an origin-form one, the `Host`
  header. Every name is checked against `[a-z0-9.-]` and ports against digits; anything else is recorded as `-`.
- Never recorded: any header (`Authorization`, `Proxy-Authorization`, `Cookie`), any body, a URL path or query.
- The filter still cannot read tunnelled traffic (end-to-end TLS); the allowlist and its exact-host matching are
  unchanged; nothing new is reachable.

The helper carries the refused hosts into the signed run result (`field egress.refused HOST:PORT:REASON_...` or `-`)
and the helper log. When the renewal host was refused, the log line says so and points here.

The service names the failure: a role that exits non-zero with the CLI's JSON result `is_error: true,
api_error_status: 401` ends `role-failed provider-auth-rejected` (was `role-failed role-crashed`). The transaction
halts at its stage with one decision request; the page explains the one action needed (§4). Nothing is retried by
itself.

## 3. Preflight: what it can and cannot say (handoff §2.4)

- **Per run (helper):** unchanged — the CLI's offline `auth status` must report a stored login, or the run is
  refused `not-authenticated` before anything starts. It is a *local* check.
- **At helper start:** the log says whether the renewal path is open (`native renewal: the CLI may renew …`) or
  blocked (`native renewal: blocked: …`).
- **`scripts/capsule-preflight`** (when the helper has `provider/egress-hosts`):
  - `PASS provider-login-stored` with a `NOTE` that it is a local check (the provider was not asked), or `FAIL` with
    the exact login command;
  - `PASS provider-renewal-path`, or `WARN provider-renewal-path` (not counted as a failure: nothing fails until the
    access token expires).
- **Remote validation** is not done. The only way found to ask the provider whether it accepts the stored sign-in is a
  real request (a renewal or a model call). Neither may run silently in a model-free preflight: a model call spends
  the owner's subscription, and both are provider traffic this handoff does not authorize. It is left for the owner to
  authorize (§5).

## 4. Owner decision requested: allow the renewal host (S1-SD1)

**Request.** Add one exact host, `platform.claude.com`, to the owner's `DIR/provider/egress-hosts` (one line). Nothing
else changes: no wildcard, no other host, end-to-end TLS, the filter still refuses everything not listed.

**Why it is needed.** It is the pinned CLI's own OAuth token endpoint, the only host it renews a subscription access
token at (§1). Without it, any role run that starts after the access token expires fails with 401 until the owner
signs in again by hand. C-P4.L.N N3 anticipated exactly this ("any further hosts the real sign-in or token refresh
needs are identified and reviewed … then added to the list"); this is that identification and review.

**What it exposes.** The role container's CLI process (and, in container mode, the tool processes, which can reach the
filter) can open TLS tunnels to `platform.claude.com:443` as well as `api.anthropic.com:443`. Both are Anthropic
hosts; the credential remains readable only by the CLI identity (C-P4.L.R3); no token enters a Dev Capsule (capsule
roles run no tools in the role container at all).

**Evidence it works (synthetic):** `check-live-renewal` part N — the same expired synthetic sign-in, with
`platform.claude.com` allowed: the CLI renewed once by itself, used only the renewed token, the run completed, the
renewed sign-in was kept in the auth volume, and the next role session used it without renewing again.

**How to apply, once decided** (the owner, not the Implementer):

```
printf 'platform.claude.com\n' >> <helper-state>/provider/egress-hosts
```

then restart the helper (`lockstep stop`, `lockstep`). The helper log must then say
`native renewal: the CLI may renew an expired access token at platform.claude.com`.

**If declined:** runs keep working while the access token is fresh; an expired one now fails with a named diagnostic
(`provider-auth-rejected`, the refused renewal host in the result and log) and one action: sign in again
(`scripts/control-helper --state <helper-state> --provider-auth-login`), then choose *Retry*.

### About `claude setup-token`

Not adopted. It is a different credential (long-lived, provisioned once) with its own lifecycle and revocation story,
and the ordinary login can renew itself once its renewal host is reachable (part N). It remains a provider-supported
fallback only if the owner declines S1-SD1 and wants unattended runs longer than an access token's life.

## 5. Real-provider renewal: not yet tested

Nothing here claims real-world renewal works. The synthetic check shows the CLI's renewal through the filter against a
stand-in. The confirming test is attended and authorized by the owner: with S1-SD1 applied, after the access token has
expired (or after the owner's ordinary use has let it lapse), run one read-only role and confirm the helper log shows
no refusal and the run is not `provider-auth-rejected`. Expected cost: one short Planner run.
