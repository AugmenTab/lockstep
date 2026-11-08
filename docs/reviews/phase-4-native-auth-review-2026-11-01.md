# Independent review — C-P4.L.N native subscription authentication (`aaefedb..130a14c`)

- Reviewer: an independent read-only agent (nothing edited, built or run), 2026-11-01. Scope: the native increment —
  the passthrough filter, the auth volume (Option D), the helper's native path, the removal of the P4.L.S injection.
- **Verdict: the token-intermediation prohibition is HONORED (confirmed). 0 HIGH, 0 MEDIUM, 2 LOW** (dead code /
  stale comments). No real token or provider call involved.

## Confirmed

- Lockstep never reads, parses, stores, injects or relays the subscription token. `read_credential` is API-key-only
  and never called on the native path; no `Authorization: Bearer` injection, `credential-mode-mismatch` or forced
  oauth beta remain in live code. The filter terminates no TLS and never reads the tunnel body; the preflight reads
  only `claude auth status` stdout; `native_tokens` parses only usage counts; `auth_ready` checks ownership/mode, not
  contents; the result and ledger carry only `egress.tokens` and `egress.micro 0`.
- The filter's `do_CONNECT` matches an exact host set, requires port 443, refuses every other method; no bypass to a
  non-allowlisted host; the role container sits only on the internal network. Preflight runs before any network/filter
  start, fails closed on a non-`loggedIn: true` status, no retry loop. The volume (owned 2000000000/700) is unreadable
  by the tools (operator uid), never mounted into the tree/input/output or a tool-only container; `native_tokens` runs
  a fixed in-image python on the CLI stdout only. `provider-auth-init/login` mount no repository, add no role-container
  capability; the Engineer cannot invoke arbitrary mounts. §7's "not the same guarantee" and the packet's limitations
  are accurate and complete.

## Findings and dispositions

| # | Finding | Disposition |
|---|---|---|
| LOW-1 | `execute_live_run` kept an unreachable `subscription*)` arm injecting a `CLAUDE_CODE_OAUTH_TOKEN` placeholder, with a stale comment (native always routes to `execute_native_run`). | **Fixed:** the arm removed; the API-key placeholder kept with a corrected comment. |
| LOW-2 | `OAUTH_BETA` constant unreferenced; stale header comments in `egress-proxy` and `agent-entry` ("the proxy holds the credential") described the removed injection. | **Fixed:** the constant removed; the comments updated for native mode. |
| INFO | `serve`+`billing subscription` would still demand an API key — unreachable (native runs `passthrough`), harmless; retained as the `describe` selector. Role container mounts `/auth` read-write (token refresh) and the brief root window runs only trusted `agent-entry`; the tools-cannot-read guarantee rests on C-P4.L.R3 (isolation 26/26, unchanged). | No change. |

After the fixes: `check-live-native` 23/23, `check-live-runner` 84/84 re-verified; `check-live-boundary` re-run with
the Docker network pool freed (the fixes are comment/dead-code only and cannot affect it).
