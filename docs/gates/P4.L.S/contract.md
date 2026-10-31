# Contract — P4.L.S Subscription-backed live runs

- Contract ID: `C-P4.L.S@v1`
- Status: **DRAFT** (frozen in §5 before implementation); amendment A-P4.L.S-1 **PROPOSED** (§6)
- Authority: the owner, 2026-10-31: "We're using subscription, not API"; "the plan from the beginning was always to use
  subscription and not API"; "go ahead". The Bible (`LOCKSTEP_PROJECT_BIBLE_v2.2`): "API billing credentials do not
  silently replace subscription-backed authentication"; "Subscription-backed usage may not expose defensible dollars per
  call. Report measured resource consumption rather than fictional prices." Handoff `.local/plans/phase-04_update6.md`.
- Basis: `phase-4` at `c32d3a7` (candidate `24cba9d`). Scope: the live provider's authentication, the CLI's start
  mode and the budget's unit. No change to the Supervisor, the engine, the isolation (C-P4.L.R3), the
  one-conversation rule (H2), terminal refusals (H1), the modes (H3) or the number of Implementers. No provider call,
  no real credential, no installation.

## 1. The finding

C-P4.L built the live path for an Anthropic API key: the proxy injects `x-api-key`, the CLI runs `--bare` (which
takes the key only from `ANTHROPIC_API_KEY`), and the ledger charges micro-USD at configured prices. The owner's
plan, and the Bible, is the owner's Claude **subscription**. Measured offline with the pinned CLI 2.1.312 and a fake
token (`.local/p4lr3/run/script-oauth*`, `script-simple`):

| # | Fact |
|---|---|
| S-F1 | With `CLAUDE_CODE_OAUTH_TOKEN` and `--bare`, the CLI stops at once: "Not logged in · Please run /login"; nothing is sent. The same with `CLAUDE_CODE_SIMPLE=1` (what `--bare` sets) and no `--bare`. |
| S-F2 | Without `--bare`, with `ANTHROPIC_BASE_URL` set, the CLI sends only `POST /v1/messages?beta=true` to that address, with `Authorization: Bearer <token>` and `anthropic-beta` = `claude-code-20250219, oauth-2025-04-20, interleaved-thinking-2025-05-14, context-management-2025-06-27, per-turn-control-2026-07-01, mid-conversation-tool-changes-2026-07-01, thinking-token-count-2026-05-13, effort-2025-11-24, extended-cache-ttl-2025-04-11`; the run completes. |
| S-F4 | Without `--bare` the CLI also offers a fourth tool, `DeferredToolPlaceholder` (its deferred-tool search), which the proxy refuses (`tool-refused`; measured in the trial). With `ENABLE_TOOL_SEARCH=false` it offers exactly `Bash`, `Edit`, `Read`, with the same features (`.local/p4lr3/run/script-nts`). |
| S-F3 | `--bare` also kept the repository's `CLAUDE.md`, auto-memory, hooks, plugins and background tasks out. The pinned CLI has switches for those that do not touch login: `CLAUDE_CODE_DISABLE_CLAUDE_MDS`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`; hooks, plugins and the repository's settings are already out (`--setting-sources user`, an empty private home, `--strict-mcp-config`, `--disable-slash-commands`, `--tools "Read Edit Bash"`). |

## 2. Decisions

| # | Decision |
|---|---|
| S1 | **Two billing modes, chosen explicitly by the owner's configuration, never by a fallback.** *Subscription* (the production mode): the configuration says `billing subscription` and has no price, long-context or budget keys; the credential is a subscription token (`sk-ant-oat01-…`, from `claude setup-token`); the proxy sends it as `Authorization: Bearer`, with the `oauth-2025-04-20` feature. *API key* (kept for the offline checks' synthetic keys, unchanged): the configuration of C-P4.L with its prices; the credential an API-style key, sent as `x-api-key`. A subscription token with an API configuration, or an API key with a subscription configuration, is refused (`credential-mode-mismatch`) before anything starts. The helper's log names the mode (`live runs on (subscription …)`). |
| S2 | **Usage, not dollars, in subscription mode.** The ledger keeps counting every request's tokens (input, cache writes, cache reads, output) and reserves before sending, against `token-limit`, `invocation-limit`, `request-max-tokens`, `invocation-output-tokens`, `invocation-requests`; its micro-USD column is 0. The run's summary reports the measured tokens; nothing reports a price. The subscription's own usage windows are the provider's and are not modelled (the Bible: UNKNOWN is not invented). |
| S3 | **The CLI without `--bare`.** The adapter's argument vector loses `--bare` (A-P4.L.S-1, §6); everything else is unchanged. agent-entry starts the CLI with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, `ENABLE_TOOL_SEARCH=false` (S-F4; the tools stay exactly the three) (with the existing `--setting-sources user`, private home and `PATH`). In subscription mode the role's container gets `CLAUDE_CODE_OAUTH_TOKEN=<placeholder>` instead of `ANTHROPIC_API_KEY=<placeholder>`; the proxy drops whatever the client sends and sets the real token. |
| S4 | **The proxy admits exactly the observed features.** `BETAS` gains `mid-conversation-tool-changes-2026-07-01` and `extended-cache-ttl-2025-04-11` (sent without `--bare` in both modes) and, in subscription mode only, `oauth-2025-04-20`. Anything else stays refused; the top-level fields are admitted as observed in the checks' runs (any addition recorded in §5 with its evidence). |
| S5 | **Unchanged:** API-key mode's behaviour for the frozen offline checks; the isolation; the one-conversation rule; terminal refusals; offline/production modes (H3); the Supervisor; the engine. |

## 3. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-subscription` (new) | host: real Docker, the real helper (offline-test mode), the real CLI | S1: a subscription configuration with a synthetic subscription token: live runs on, the log names subscription; the upstream receives `Authorization: Bearer <that token>` and no `x-api-key`, and the `oauth-2025-04-20` feature; the role's container sees only a placeholder, never the token. A subscription token with an API configuration, and an API key with a subscription configuration: live runs off, `credential-mode-mismatch`, nothing sent. S2: the ledger's micro-USD 0, its tokens counted; a token limit reached stops the run `token-limit-reached`. S3: the repository's `CLAUDE.md`, `.claude/skills`, `.claude/agents`, `.claude/commands` and `.mcp.json` (each with a marker) are not in any request; only `Read`, `Edit`, `Bash` offered; only `/v1/messages`. A development run (edit, command, answer) completes with its answer in subscription mode |
| `scripts/lib/live-standin-headers` (new) | test tool | the scripted stand-in (secret ids) that also records each request's path, its auth headers (the bearer compared with the expected token, never logged) and its features, and which markers appear in the body |
| The frozen live checks (unchanged): `check-live-runner`, `-boundary`, `-concurrency`, `-proxy`, `-impersonation`, `-isolation` | host | API-key mode and everything else unchanged, with the CLI now without `--bare` |
| `test/fixtures/live/claude-argv`, `test/unit/Lockstep/Effects/ClaudeAdapterTest.hs`, `test/integration/Lockstep/LiveAdapterTest.hs` | frozen; A-P4.L.S-1 | the argument vector without `--bare` |

## 4. Allowed paths

Production: `scripts/runner/provider/egress-proxy`, `scripts/runner/provider/agent-entry`, `scripts/control-helper`
(the provider's start and the live run's environment), `src/Lockstep/Effects/Provider/Claude.hs` (the argument
vector and its comment). Tests: §3. Documents: `docs/gates/P4.L.S/`, `docs/gates/P4.L/budget-report.md`,
`docs/gates/P4.L/real-provider-smoke-proposal.md`, `docs/OPERATOR_GUIDE.md`, `docs/reviews/`.

## 5. Freeze record

- Frozen 2026-10-31 by the single writing agent (Implementer, manual), on `phase-4` after `c32d3a7`, before any
  production change.

  | File | sha256 |
  |---|---|
  | `scripts/lib/check-live-subscription` | `f5fd8dcbc9a7f65fca031ce9f29b987add2e637e0a557cd7e0e8b014f0ab3f60` |
  | `scripts/lib/live-standin-headers` | `872df3a470d7943e452238021ce20f0ebdda2a201203847ba9f4af2e71e51877` |

- Baseline against `24cba9d` (`.local/p4ls-red-baseline.log`): **6 failures, each the finding** — a subscription
  configuration is not a configuration (live runs off) in each of the three subscription cases; an API configuration
  accepts a subscription token and sends it upstream (`nothing was sent` fails); the helper names no subscription mode.
  The expectations inside a subscription run do not execute at baseline (no run can be submitted without the offline
  mode on); they are counted at GREEN.
- Three test faults fixed before this baseline: the helper's log was read across helper restarts (a run was
  submitted with live runs off); a mode check matched the state directory's own name; empty fields passed or erred.

## 6. Amendment A-P4.L.S-1

`docs/gates/P4.L.S/amendments.md` (for the Planner).
