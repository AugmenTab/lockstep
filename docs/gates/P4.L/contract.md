# Contract — P4.L The first live provider, offline: Claude Code adapter, restricted egress, credentials, budget

- Contract ID: `C-P4.L@v1`
- Status: **FROZEN** (§5)
- Authority: `.local/plans/phase-04_update3.md` (sha256 `97c86589…2da6a12`) §4–§9 (Workstreams B1–B3, the spending
  correction, the required scenarios); DG-17 ACCEPTED (D-17.1 a container per role, D-17.6 provider flags defence in
  depth only, D-17.7 limits, D-17.8 Claude Code first behind a provider-neutral interface); C-P4.5 A5/A6 (the role
  invocation interface; §3a, the adapter NOT_BUILT until now); C-P4.2 R3/R4 (the helper's container runner).
- Writer: the single writing agent (Implementer, manual). Live use stays separately authorized: **nothing here
  calls a provider, holds a real credential, installs anything or starts the operator's helper.**
- Basis: `phase-4` at `b0b922d` (C-P4.R3).

## 1. What P4.L delivers

1. **The live adapter** (B1): `Lockstep.Effects.Provider.Claude` (the provider line, the CLI's argument vector,
   the role's instructions) and `Lockstep.Effects.Provider.Live` (the one place the live runner and adapter are
   put together; only `app/lockstep/Main.hs` imports it, guard (c)). `lockstep serve` runs every role live when
   the helper's runner channel holds a provider line.
2. **Restricted egress** (B2): the helper's `run-live-readonly` / `run-live-write` operations, and the egress
   proxy (`scripts/runner/provider/egress-proxy`) in the pinned provider image
   (`scripts/runner/provider/Dockerfile`, `scripts/provider-image`).
3. **Invocation-scoped credentials** (B3): the owner's key lives in the helper's own `DIR/provider/credential`,
   and only the proxy of one live run ever reads it.
4. **The budget** (§7 of the handoff): a durable ledger the proxy writes; a reservation of each request's largest
   possible charge before it is sent; per-run and whole-trial limits.

## 2. Decisions

| # | Decision |
|---|---|
| L1 | **Adapter.** Program: the pinned Claude Code CLI 2.1.312 (`claude -p --bare --model M --effort E --tools "Read Edit Bash" --dangerously-skip-permissions --no-session-persistence --output-format json --strict-mcp-config --disable-slash-commands --session-id <the run's name as a UUID> "<read /input/role.md>"`; exactly `test/fixtures/live/claude-argv`). `--bare`: no hook, plugin, CLAUDE.md, stored login or keychain; the key only from `ANTHROPIC_API_KEY`. The same three tools for every role (the CLI's own tool names, observed); which role may change the tree is the mount (C-P4.2), never the tools. The role's instructions in `/input/role.md` (who it is, where things are, the answer's exact shape, project text is material); the answer only through `result.json` (C-P4.5 A5, unchanged). Models offered: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-fable-5-1`; efforts `low`, `medium`, `high`, `xhigh`, `max`. Anything else is refused (`provider-model-unsupported`, `provider-effort-unsupported`, `provider-unsupported`, `provider-file-invalid`); never an alias, a fallback model or an adaptive effort. The provider line (`DIR/runner/provider`: `lockstep-provider 1 claude-code MODEL EFFORT`) is written only by the helper; a line that cannot be used turns the service's worker off with its reason. |
| L2 | **Egress.** A live run gets its own `--internal` Docker network whose only other member is the run's proxy (alias `lockstep-egress`). The role's container: the provider image, that network only, read-only root, no capabilities, no new privileges, the invoking user, the C-P4.2 mounts and limits; `ANTHROPIC_BASE_URL=http://lockstep-egress:8080`, a placeholder key, telemetry, error reports and updates off, `CLAUDE_CODE_MAX_OUTPUT_TOKENS` = the owner's per-request limit. The proxy: started first, listens only on the run's network, then joins the egress network; answers only `POST /v1/messages[?beta=true]`; sends it only to the fixed upstream `api.anthropic.com:443` (TLS verified), whatever the request names; never follows or passes on a redirect (`502 redirect-refused`); admits a request only with the configured model and effort, `max_tokens` within the limit, only the role's tools (no agent, server tool or MCP server), text, tool and thinking blocks only (no image or document), and only the six beta features the pinned CLI sends (observed). Every refusal is counted and the run is then `provider-stopped <code>`. A proxy that is gone, never ready or gone before the run ends: `provider-stopped egress-failed`; the run is killed within a second. Every other operation, verification and scripted roles included, keeps `--network none`. Lifetimes: proxy, run and network removed after every run; a restarted helper removes any left. |
| L3 | **Outcome.** The helper's result for a live run carries the proxy's summary (`egress.*`: model, effort, pricing, requests, denied, forwarded, known/unknown usage, tokens by kind, the charge, the budget spent so far, statuses, beta features and paths seen) and, when stopped, `provider-stop <code>`. The service reads `provider-stopped` as `ProviderStopped code` (a code of 1–40 of `a–z` and `-`, else the result is invalid, an unknown outcome) and the role as `RoleFailed "provider-stopped <code>"`: whatever it wrote is not an answer; the fix halts for a person and nothing is run again by itself. |
| L4 | **Credential.** The owner's key: `DIR/provider/credential` (0600, owned, a regular file, not a link, `sk-ant-` and 16–400 of `A–Za–z0–9_-`). Checked before each live run (`credential-missing`, `credential-unusable`, `credential-malformed`: nothing starts). Mounted read-only into that run's proxy only; the proxy drops any key a request carries and sets the owner's. The role's container, the service, the runner channel, the run's files, results, journals, logs, the ledger and the run summaries never hold it. Removed with the proxy at the end of the run. A provider that refuses it: `provider-stopped auth-refused`. |
| L5 | **Budget.** The owner's configuration (`DIR/provider/config`: model, effort, a named pricing basis in micro-USD per million tokens for input, output, 5-minute and 1-hour cache writes and cache reads, long-context prices, and the limits). Before a run: the ledger is readable, fewer than `invocation-limit` live runs, something left of the budget and the token limit (`budget-exhausted`, `token-limit-reached`, `invocation-limit-reached`, `ledger-unreadable`: nothing starts). Before each request: its **reservation**, the largest charge it can cause (every prompt byte counted as a token, plus 4096, at the dearest input price, plus `max_tokens` at the output price, at long-context prices when the prompt could be long), must fit what is left of the budget and the token limit, and the run's output-token and request allowances; it is written to the ledger (append-only, synced) before the request is sent. After: settled at the provider's reported usage; a response whose usage cannot be read stays charged at its reservation and stops the run (`usage-unknown`); a request never settled (the proxy stopped mid-request) stays charged. The ledger is the helper's, for the whole budget across runs, restarts and retries; nothing a request or the service sends can reset it. |
| L6 | **Model-free qualification.** Nothing in this contract contacts a provider. The host check's upstream is a local stand-in (`scripts/lib/live-standin`, HTTPS with a certificate made by the check) on an internal network; the test overrides (`LOCKSTEP_RUNNER_TEST_UPSTREAM`, `…_UPSTREAM_CA`, `…_EGRESS_NETWORK`) are read at helper start only, as `LOCKSTEP_RUNNER_TEST_LIMITS` is. The deterministic suites keep the sentinel `claude` shim and never run the CLI. |

## 3. What this does not establish

- That a real model can do the work; real prices; the real upstream's TLS and rate limits. Those are the smoke's.
- That the reservation formula's assumption (a prompt has no more tokens than bytes, plus 4096) holds for every
  request: it holds for text; images and documents, where it may not, are refused (L2).
- That the pricing basis is current: the owner names and confirms it (`pricing` in the configuration).

## 4. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Effects/ClaudeAdapterTest.hs` | unit | L1 the provider line (every offered model and effort; refusals; malformed lines); the argument vector equal to the fixture; no agent, web, MCP, fallback or kept session; each role's instructions; L2 the live profiles and operations; L3 `provider-stopped` and its code |
| `test/integration/Lockstep/LiveAdapterTest.hs` | integration: real PostgreSQL, Git and engine; a stand-in for the live container | L5-A an answer through the adapter (argv, model, effort, session, instructions; recorded with adapter `claude-code`); L5-B budget, unknown usage and egress failure halt and are not run again; L5-C malformed, absent, oversized, wrong-kind answers refused; L5-D an unknown outcome halts, a restart runs nothing again; L5-E an answer whose recording failed is kept and used after a restart, the CLI not run again; L5-F `lockstep serve` with a provider line: the first role request is `run-live-readonly` with the CLI's argv and instructions; L5-G a line it cannot use: worker off with the reason |
| `scripts/lib/check-live-runner` | host: real Docker, the real helper, the real provider image and CLI, the real proxy; the stand-in upstream | 84 checks (an earlier count of 86 was the writer's miscount; see §5): provider off/on; unsupported model and effort; the real CLI answering through the proxy (answer, usage, ledger, endpoint, key, tools); a missing CLI; the network (one interface, no outside address, no upstream, no name, no host, no other port); 12 proxy refusals and none reaching the upstream; Host header; redirect; unknown usage; refused credential; no agent; request limit; budget before and during a run and after a helper restart; token and invocation limits; the credential nowhere; credential refusals; read-only and write trees, protected test; one run at a time; verification and scripted runs offline; timeout, cancel, proxy gone (in-flight request stays charged), helper killed (interrupted; leftovers removed) |
| `scripts/lib/live-standin`, `scripts/lib/live-probe-client`, `test/fixtures/live/claude-argv` | test tools | the stand-in upstream; the in-container probes; the argument vector shared by the unit test and the host check |
| `test/unit/Main.hs`, `test/integration/Main.hs` | runners, additive | — |

The frozen `scripts/lib/check-runner` (C-P4.2) and `scripts/lib/check-runner-paths` (C-P4.R1) must still pass
with the changed helper.

## 5. Freeze record

- Frozen 2026-10-29 by the single writing agent (Implementer, manual), on `phase-4` after `b0b922d`.
- Frozen files (Haskell formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/unit/Lockstep/Effects/ClaudeAdapterTest.hs` | `bc0ff3c05eb70695c9d0c238b1a80fec10cf21553fe11886b83ce37916329058` |
  | `test/unit/Main.hs` (one group added) | `e9ca9469fc20b6306312256957e95e0b9e930d3751655f227f24519641f91286` |
  | `test/integration/Lockstep/LiveAdapterTest.hs` | `aa16c10647cbaa1c5b0c7999b13a8670b1384cb20199ccd403c70b0e21e753bc` |
  | `test/integration/Main.hs` (one group added) | `82a5e384a8a8d5d9c504fcf7c15646938757374978449803290201abc959f845` |
  | `scripts/lib/check-live-runner` | `93f97461cf5f77bde5ebb7341e0b25ca2bc8b3566704339a5045b260b12e7943` |
  | `scripts/lib/live-standin` | `6589bf3ed83839f3110ac5b91d05c7beaadf2ff6c3263145eef03ba7a410bf57` |
  | `scripts/lib/live-probe-client` | `6eef9c7efc038dc253291f72dc920a6616fa2d430e7132be6b5d1f657699a30a` |
  | `test/fixtures/live/claude-argv` | `2ed204fce6dc775097294107190a45154ae1d3a3092fc39f75f7d8f436fb16c2` |

- Stubs in the freeze commit: `Lockstep.Effects.Provider.Claude` (the names, nothing built), `liveProfile` the
  identity, `ProviderStopped` read as `not-implemented`; `HelperRunner`, `Main` and `scripts/control-helper` as at
  `b0b922d` (no live operation, no provider line). The types (`ProviderStopped`, the live profiles) are in.
- Baselines against the stubs (logs `.local/p4l-baseline-{unit,integration,host}.log`): unit **8 of 8 fail**;
  integration **7 of 7 fail** (no instructions or argv written: the stand-in container finds no `role.md`; the
  service runs no live engine and reads no provider line); host: **44 fail, 9 pass, then the check stops** at the
  budget case (no ledger: the helper has no live operation, `unknown-op`). The 9 that pass hold only because
  nothing ran (nothing left over, nothing reached the stand-in, no provider line).
- Trial before the freeze (the implementation since kept in `.local/p4l-impl/`): unit 8 of 8, integration 7 of 7,
  host **84 of 84** (`.local/evidence/live-20261029t160100z/results.txt`; recorded at first, and in the commit
  message of `c7a6d54`, as "86 of 86": a miscount, corrected here — the file has 84 `PASS` lines and no `FAIL`); the frozen `check-runner` 0 failures with
  the changed helper. Found and fixed in trial, not in the tests: the ledger's settle lines miscounted (every run
  after the first was refused `ledger-unreadable`); the CLI's own default `max_tokens` above the limit (the helper
  now sets `CLAUDE_CODE_MAX_OUTPUT_TOKENS`); a run that outlived its proxy reported `exited` (now `egress-failed`,
  and a request never settled is `usage-unknown`); the runner name `container-live` refused by the invocation
  table's check (the live runner is `container` on the record); a provider file of two lines read as one.
  Test-side corrections before the freeze: credential changes are written in place and given 3 s to reach the
  container (the Mac's file sharing showed a renamed file or a mode change late; each case failed closed).
- After the freeze (writer's slip, recorded): the two frozen test modules were committed without running `hlint`,
  which then gave six style hints in them (`Redundant <$>` ×4 in `Lockstep.LiveAdapterTest`; `Avoid lambda`, `Eta
  reduce` in `Lockstep.Effects.ClaudeAdapterTest`). The frozen files are unchanged; `.hlint.yaml` ignores exactly
  those three hint names within exactly those two modules. No check's meaning changes.

## 6. Allowed paths

New: `src/Lockstep/Effects/Provider/{Claude,Live}.hs`, `scripts/runner/provider/{Dockerfile,egress-proxy}`,
`scripts/provider-image`, the test files of §4, `docs/gates/P4.L/**`. Changed: `src/Lockstep/Kernel/Runner.hs`
(`ProviderStopped`), `src/Lockstep/Foundation/RunnerProtocol.hs` (live profiles), `src/Lockstep/Effects/{Roles,
HelperRunner}.hs`, `app/lockstep/Main.hs`, `scripts/control-helper`, `lockstep.cabal`, `docs/OPERATOR_GUIDE.md`,
`docs/gates/C-EXEC/**`, `docs/governance/DECISION_REGISTER.md`. No migration; no new persistence (the invocation's
argv names its run, whose usage the helper's ledger keeps).

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen check. Stop and ask if a change would need the Supervisor's
authority to change, a provider call, a real credential, or the operator's installation. Rollback: revert the
commits; remove the image `lockstep-provider:claude-2.1.312`.
