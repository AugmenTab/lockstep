# Contract — P4.L.N Native subscription authentication (the CLI holds its own token)

- Contract ID: `C-P4.L.N@v1`
- Status: **DRAFT** (frozen in §5 before implementation)
- Authority: `.local/plans/phase-04_update7.md` (owner/Planner, 2026-10-31): subscription through the official,
  unmodified CLI; no API-key billing or fallback; no token substitution or credential proxying; Lockstep never
  collects, parses, stores, substitutes or relays the token; the owner signs in through Anthropic's own flow. The
  credential-boundary disposition (`docs/gates/P4.L.S/credential-boundary.md`) chose this path.
- Basis: `phase-4` at `8976c42`. Scope: how a live role run reaches the provider and how the CLI's own
  authentication state is mounted. No change to the Supervisor, the engine, the CLI/tool isolation (C-P4.L.R3), the
  Implementer count, or the adapter's argument vector (already without `--bare`, A-P4.L.S-1). **No credential-security
  experiments** (update7 §1, deferred).

## 1. What the official CLI provides (from `claude --help`, `claude auth …`, captured offline; no account, no network)

| # | Fact |
|---|---|
| N-F1 | `claude auth login --claudeai` signs in with a Claude subscription through Anthropic's own flow (the default; `--console` is API billing, not used). `claude auth logout`, `claude auth status [--json|--text]`. |
| N-F2 | `claude auth status` with no sign-in prints JSON `{"loggedIn": false, "authMethod": "none", … "configDirectory": "<dir>"}` and exits non-zero; it reads only the config directory, no network. It is the preflight. |
| N-F3 | The CLI keeps its sign-in state under its config directory (`$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`), reported as `configDirectory`. A dedicated directory, separate from the operator's `~/.claude`, holds only this. |
| N-F4 | `--max-turns N` bounds a print-mode run's turns (accepted by 2.1.312). |
| N-F5 | Not `--bare`: it forces `ANTHROPIC_API_KEY`/`apiKeyHelper` and never reads OAuth. The adapter already omits it (A-P4.L.S-1); the image keeps the repository's configuration out by other means (C-P4.L.S S3, C-P4.L.R3). |

## 2. Decisions

| # | Decision |
|---|---|
| N1 | **The CLI owns its authentication, in a dedicated Docker named volume** (Option D, amendment A-P4.L.N-1, Planner 2026-11-01). A persistent named volume (`lockstep-provider-auth-<instance>`) holds only the CLI's own sign-in state. The trusted host helper (never the Engineer) manages it: (i) **initialization** — a one-off container, outside the ordinary role container, creates the volume and sets its ownership and mode to the CLI identity (uid 2000000000, 0700); this is the only place ownership is set, and the ordinary role container gains **no** new capability. (ii) **operator login** — the owner runs `claude auth login --claudeai` in a separate, temporary login container (the same provider image, the same volume at the CLI's `$CLAUDE_CONFIG_DIR`, the same CLI identity), completing Anthropic's official flow; no untrusted repository and no unrelated host credential is mounted there; no token is copied or injected. (iii) **container identity** — a live role run mounts the volume at the CLI's `$CLAUDE_CONFIG_DIR`, owned by and readable only by the CLI identity; the tools' identity (the operator's uid) cannot traverse or read it, because the volume is owned by 2000000000, not by the operator. (iv) **restarts** — the volume persists across role-container recreation and after the login container is destroyed, so a refreshed token stays; Lockstep neither prompts nor refreshes. (v) **the macOS/Docker boundary** — the volume is Docker-managed, so its ownership does not depend on the host filesystem's uid mapping; the login runs in a container, not against the host keychain. Lockstep never reads, parses, copies or modifies the credential content in the volume; it only creates the volume and sets the empty volume's ownership. It is **not** mounted into the tree, the input, the output, or any tool-only container. |
| N2 | **No token in Lockstep.** The egress proxy's subscription token-injection mode (C-P4.L.S) is **removed**. In its place a **passthrough egress filter**: it accepts only `CONNECT <allowed-host>:443` and relays the bytes, end-to-end TLS; it cannot read the request or the token, follows nothing else, and refuses any other host or method. The API-key mode's inspecting proxy stays only for the offline checks' synthetic keys (not the smoke). |
| N3 | **The allowed hosts: explicit, configurable, no wildcard** (Planner clarification 3). The filter allows only a list of exact hostnames the operator configures (`DIR/provider/egress-hosts`, one host a line); it is never a suffix or wildcard. `api.anthropic.com` is the Messages endpoint (observed) and the default. Any further hosts the real sign-in or token refresh needs are **identified and reviewed during the authorized attended setup**, then added to the list — the operator is not asked to discover endpoints by hand, and no blanket domain is approved. Nothing else is reachable; the role's other containers keep `--network none`. |
| N4 | **Preflight, no retry loop.** Before a live role run the helper runs `claude auth status --json` in the provider image against the mounted config directory, no network: if `loggedIn` is not true, the run is refused `not-authenticated` and the engine halts for the operator with a clear message; it is not retried by itself (the existing halt, as for any refusal). |
| N5 | **Limits without dollars.** Per run: the wall clock (C-P4.L.R1), `--max-turns`, the engine's retry budget, one run at a time, the invocation count (the helper's). Usage is read from the CLI's own `result.json` (`usage`: input, output, cache tokens) and recorded as measured tokens; no price, no dollar budget (update7 §5; the Bible). The durable ledger keeps counting invocations and tokens for the record; it enforces no spend. |
| N6 | **The single-code-writer invariant is the engine's, and is not the proxy's old one-conversation guarantee** (Planner clarification 2). Two distinct things, not to be conflated: (a) *the engine's invariant* — one Implementer invocation writes to the tree at a time, and only the Supervisor accepts a result into Git; this is unchanged by native auth and does not depend on the proxy. (b) *the proxy's former control* (C-P4.L.R2 H1/H2) — reading every request, it made it impossible to open a second model *conversation* even from inside the role container, and stopped a run at the first refusal. With end-to-end TLS the proxy no longer sees requests, so **(b) is gone**. What stands in for part of it: the credential is reachable only by the CLI's identity (N1, C-P4.L.R3), so repository code run by the tools cannot authenticate a model conversation of its own. What is **not** recovered: a wire-level bound on what the authenticated CLI itself sends. The honest statement is §7. |
| N7 | **Unchanged:** the CLI/tool isolation and its checks (C-P4.L.R3); the role container's mounts, limits, capabilities and two identities; `--network none` for scripted roles and checks; the Supervisor; the engine; the adapter's argument vector; the API-key offline mode. |

## 3. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-native` (amended A-P4.L.N-1) | host: real Docker, the real helper, the real CLI, a stand-in | N4: a volume holding a synthetic "logged in" state → the run proceeds; an empty (initialized but unauthenticated) volume → refused `not-authenticated`, not retried, no upstream reached. N1: the auth volume is owned by the CLI identity; the tools' identity cannot traverse or read it; the volume is not in the tree, input, output or a tool-only container; the state persists after the login container is destroyed and across role-container recreation; the repository tree stays writable by the operator identity. N2/N3: the passthrough filter relays `CONNECT api.anthropic.com:443` (to a stand-in on an internal network) and refuses another host, another method, a plain request; it never sees the body. N5: usage recorded in tokens from result.json; no dollar field. N6: no token env in the role container; no new role-container capability. A simulated transaction (edit, command, answer) completes, the CLI reaching the stand-in only through the filter |
| `scripts/lib/live-auth-stub` (new) | test tool | a tiny program the image runs in place of `claude auth status` for the check's two states, and a CONNECT client/echo pair for the filter; never the real login |
| The frozen live checks (unchanged): `-isolation`, `-impersonation`, `-runner`, `-boundary`, `-concurrency`, `-proxy`, `-subscription` | host | the isolation and the API-key/offline paths stay green |

The check uses a **synthetic** authentication state (a `.credentials.json` the check writes into the volume as the CLI
identity), never a real token and never `claude auth login`; no provider is contacted (the upstream is a local
stand-in on an internal network). **The preflight check establishes offline behavior only** — that an unauthenticated
state refuses and a synthetic authenticated state proceeds — and is **not** evidence that real subscription
authentication succeeds; that is shown only at the attended smoke (Planner). The filesystem tests show the tools'
identity cannot read the volume; they are **not** proof against every in-process, model-directed file operation by the
CLI itself (recorded as a residual, §7).

## 4. Allowed paths

Production: `scripts/runner/provider/egress-proxy` (the passthrough mode; the subscription injection mode removed),
`scripts/runner/provider/connect-filter` (new, if separate), `scripts/control-helper` (the config-dir mount, the
preflight, the filter instead of the proxy for native mode), `scripts/runner/provider/Dockerfile` (if the filter is a
new file), `scripts/provider-image`. Tests: §3. Documents: `docs/gates/P4.L.N/`, `docs/gates/P4.L/`,
`docs/OPERATOR_GUIDE.md`.

## 5. Freeze record

- Frozen 2026-10-31 by the single writing agent (Implementer, manual), on `phase-4` after `8976c42`.

  | File | sha256 |
  |---|---|
  | `scripts/lib/check-live-native` (frozen `aaefedb`, amended A-P4.L.N-1) | `089e1349264a067dc805342a3fd1eba0d5d2212a4f7050c726c4aced6b258e38` |
  | `scripts/lib/live-connect-probe` | `3e1614a11d2db03cd8ed1418fe9fd3f4a725c67e493e55639e79d315a688d239` |

  Amendment A-P4.L.N-1 (Planner, 2026-11-01, Option D): `check-live-native` reworked from a host config-dir bind mount
  to the dedicated Docker named volume (original `832c03b6…c69a6` → `089e1349264a067dc805342a3fd1eba0d5d2212a4f7050c726c4aced6b258e38`);
  N1, §3 and §6 amended with it. No GREEN result existed before the amendment (it was frozen RED on the native path),
  so no qualified behaviour is removed. One redundant assertion (the offered tool set, covered by `check-live-boundary`)
  was dropped while refining the amendment before GREEN, since the frozen stand-in `live-standin-secret` does not log
  the tool list.
- GREEN at the implementation: **23/23** (`.local/evidence/live-native-<stamp>/`).

- Supersession: `check-live-subscription` and `live-standin-headers` (frozen `3764f93`, C-P4.L.S) are retired with this
  increment (`docs/gates/P4.L.N/supersedes.md`, Planner-approved); the token-injection mode they verified is removed.
- Baseline (RED): the native path is absent — Part B (the helper's native mode) fails in full. Part A (the passthrough
  filter) passes because the filter was prepared and verified ahead in the sanctioned trial (`.local/p4ln/filter-trial.sh`);
  the implementation under test here is the helper's native mode and the removal of the injection path. (`.local/p4ln-red-baseline.log`.)

## 6. The egress allowlist (Planner clarification 3, resolved)

The filter allows only an explicit, operator-configured list of exact hostnames (`DIR/provider/egress-hosts`), never
a wildcard or suffix. `api.anthropic.com` is known (the Messages endpoint) and is the default and the only host the
offline qualification needs (the stand-in answers in its place). Any further hosts the real sign-in or token refresh
requires are **identified and reviewed during the authorized attended setup** and added to the list then; the operator
is not asked to discover endpoints by hand, and no blanket domain is approved. This changes no isolation.

## 7. The change from C-P4.L.R2, stated plainly (Planner clarification 2)

C-P4.L.R2 had the proxy read every request, so it could (H2) refuse a second model conversation started from inside
the role container and (H1) stop a run at its first refusal, and check each request's model, tools and fields. Native
authentication puts the TLS between the CLI and Anthropic beyond Lockstep's reading — the owner's and Anthropic's
requirement — so **those wire-level controls are gone**. What remains is weaker and different, and must not be
described as the same guarantee:

- **The engine's single-code-writer invariant stands** (unchanged, not from the proxy): one Implementer invocation at
  a time writes the tree, and only the Supervisor commits. A second *invocation* cannot be accepted.
- **The credential is unreachable by repository code** (C-P4.L.R3): a tool process cannot read the CLI's sign-in state
  or environment, so it cannot authenticate a model conversation of its own. This replaces part of H2 — a second
  *independent* conversation — but by isolation, not by inspection.
- **Not recovered:** a bound on what the one authenticated CLI itself sends (model, tools, fields, how many requests
  within a turn). The CLI's fixed flags set the model, effort and tools; `--max-turns`, the wall clock and the
  engine's retry budget bound the run; token usage is recorded after the fact. There is no per-request refusal at the
  wire. A defect in the CLI, or the CLI being induced by repository text to do more within its turn, is not caught by
  an egress proxy any more; it is bounded by the tools' own container isolation (C-P4.2, C-P4.L.R3) and the turn and
  time limits. This is the deliberate trade the owner chose for subscription compliance; it is recorded as a residual
  for the owner, not claimed closed.
