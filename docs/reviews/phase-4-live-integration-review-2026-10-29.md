# Phase 4 live provider integration (C-P4.L) — independent review

- Reviewer: independent read-only agent (did not write this code; built, ran, tested nothing; no network, no provider contact)
- Date: 2026-10-29
- Range: `b0b922d..c7a6d54` (branch `phase-4`), HEAD `c7a6d54`
- Basis: `docs/gates/P4.L/contract.md`, `.local/plans/phase-04_update3.md` §4–§8, and the code itself
- Method: read the whole diff, the egress proxy, the helper's live path, the Haskell wiring, the three host-check
  tools and the two frozen test modules. Line numbers are at `c7a6d54`.

## Summary

| Severity | Count |
|---|---|
| HIGH | 0 |
| MEDIUM | 2 |
| LOW | 8 |
| INFO | 8 |

No reachable credential leak, egress escape, or write by a read-only role was found. The weak spots are in the
budget's **coverage of the request body**. The proxy validates a parsed copy of the body but forwards the raw
bytes. It also allows any top-level field it does not know. Both let a hostile model make the upstream do or charge
something the reservation did not price. Both are untested.

## Findings

| ID | Sev | Where | Claim affected | Test covers? |
|---|---|---|---|---|
| M1 | MEDIUM | `scripts/runner/provider/egress-proxy:548-569` | L2 admission and L5 reservation "whatever the request names" | No |
| M2 | MEDIUM | `egress-proxy:259-316` | L5 "the largest charge it can cause" | No |
| L1 | LOW | `egress-proxy:189-210`, `665-667` | L5 "nothing a request or the service sends can reset it" | No |
| L2 | LOW | `egress-proxy:99-101, 425-427, 548-553, 460-479` | L2 "every refusal is counted and the run is then provider-stopped" | No |
| L3 | LOW | `scripts/control-helper:~1398-1412`; `src/Lockstep/Effects/Roles.hs:282-287` | wall clock: a run that runs too long is `timed-out` | Only with a 6 s test limit |
| L4 | LOW | `egress-proxy:485-491, 572-577, 612-615` | the budget report reflects spend | No |
| L5 | LOW | `egress-proxy:275-277` | L2 "only with the configured ... effort" | No |
| L6 | LOW | image + `control-helper:~1376-1394` | handoff §4: no subagent or hidden multi-agent work | Partly (test 11 covers only the CLI's Task tool) |
| L7 | LOW | `egress-proxy:381-390` | settle at "the provider's reported usage" | No |
| L8 | LOW | `control-helper:~1398-1412, 1167-1182` | L2 lifetimes; the run is bounded in time | Test 21 (restart only) |
| I1–I8 | INFO | see below | — | — |

## Details

### M1 (MEDIUM): the proxy checks a parsed copy and forwards the raw bytes, so parser differences pass through

- **Claim:** L2 says the proxy admits a request only with the configured model and `max_tokens` within the limit,
  only the role's tools, no server tool or MCP server, "whatever the request names". L5 says the reservation is the
  request's largest possible charge.
- **Code:** `body = self.rfile.read(...)` (548). `check_request(..., body, ...)` runs `json.loads(body)` (261).
  Then `connection.request("POST", ..., body, headers)` (569) sends the **original bytes** upstream.
- **What goes wrong:** Python's `json.loads` keeps the **last** value of a duplicate key and says nothing. The
  hostile model can send a body with duplicate keys, for example:
  - `{"model":"claude-fable-5-1", ..., "model":"<configured>"}`
  - `{"tools":[{"type":"web_fetch_20260209","name":"web_fetch"}], "tools":[]}`
  - `{"max_tokens":128000, "max_tokens":100}`

  The proxy sees only the last values and admits the request. If the upstream parser keeps the **first** value, or
  merges the duplicates, the request runs on a dearer model or with a larger `max_tokens`. The reservation and the
  settlement still use the configured prices. With a server tool (`web_fetch`, `web_search`, code execution,
  `mcp_servers`), the provider would reach third-party hosts for the role, which is egress by proxy. If
  `server_tool_use` appears in the usage, the request is charged at its reservation (`usage_from`, 331-333), but
  the reservation does not include server-tool fees.
- **Reachable?** It depends on how the upstream handles duplicate keys, which this review cannot verify offline.
  Many parsers keep the last value; some reject duplicates. If the upstream keeps the first value or merges, this
  is HIGH (an egress escape through server tools, and a budget overrun).
- **Fix:** forward the validated object, not the raw bytes: `json.dumps(request, separators=(",", ":"))`, with
  the reservation computed on the forwarded length. Also reject duplicate keys with
  `object_pairs_hook`, and reject `NaN`/`Infinity` with `parse_constant`.
- **Test:** none. `live-probe-client` sends only well-formed single-key bodies.

### M2 (MEDIUM): top-level fields are filtered by a denylist, so fields that change the price get through

- **Claim:** L5 says the reservation is "the largest charge it can cause".
- **Code:** `check_request` looks at `model`, `max_tokens`, `mcp_servers`, `container`, `output_config`, `tools`,
  `system` and `messages`. Every other top-level key is passed upstream unchanged.
- **What goes wrong:** the Messages API has top-level parameters that change what a request costs or where it
  runs, and need no beta header. The clearest is `inference_geo` (a direct top-level parameter; the usage reports
  where inference ran; data-residency inference is priced at a premium). A role adding `"inference_geo":"us"` is
  billed above the configured basis. The reservation, the settlement and the token limit never see the
  difference. `service_tier` and any parameter the provider adds later fall in the same gap.

  The beta allowlist does block the documented premium paths that need a beta header (fast mode
  `speed:"fast"` needs `fast-mode-2026-02-01`, which is refused). Only the header-free parameters are open.
- **Impact:** the real dollar spend can exceed `budget-micro-usd` by the price multiplier. Spend stays bounded,
  but the "hard cap" is no longer hard.
- **Fix:** an allowlist of top-level keys: exactly the keys the pinned CLI sends, which the stand-in already
  records as `top_keys`. Refuse anything else (`body-refused`), the way beta features are handled. Optionally also
  check that `usage.service_tier` and `usage.inference_geo` are the expected values, or treat the usage as unknown.
- **Test:** none. The refusal probes cover only the named denylist keys.

### L1 (LOW): ledger reservations are keyed by (run, request number), so reusing a run name drops unsettled charges

- **Code:** `totals()` keeps open reservations in a dict keyed by `(run, n)` (197) and removes the entry on a
  settle (199). `serve` does not refuse a run that already has an `invocation` line (665-667). The helper's
  `run_refusal` does not refuse a run directory that has already run (`control-helper:1223-1254`).
- **What goes wrong:**
  1. Run R's proxy is killed mid-request. `reserve R 1 X` stays open, so X is charged.
  2. Anyone holding the runner channel key (the service) asks for `run-live-*` on R again.
  3. The new proxy writes `reserve R 1 Y`, which **replaces** X in the dict, then `settle R 1 ...`.
  4. The charge X is lost.
- **Reachable?** Only if the service misbehaves. `prepareRun` uses random names
  (`HelperRunner.hs:86-93`). It is still an explicit claim.
- **Fix:** refuse `serve` (or admission) when the ledger already has `invocation RUN`; or key reservations by the
  invocation's line, not by the run name.

### L2 (LOW): some refusals and failures are not recorded as a stop

- **Code:**
  - `"ledger-unreadable"`, raised inside `admit_request` (467) and answered with a 403, is not in `STOPPING`, so
    `note_stop` ignores it.
  - A deeply nested body raises `RecursionError` from `json.loads`. That is not a `ValueError`, so it escapes
    `check_request` and `do_POST`. The connection drops with no `deny()`.
  - An `OSError` from `ledger.append` in `admit_request` also escapes, after `self.requests` was already raised in
    memory but before the summary is rewritten.
- **Effect:** in each case the summary keeps `stop -`, and the helper decides the outcome from `stop` alone. If the
  CLI still exits 0 with a `result.json` built on earlier turns, the run is `exited` and the answer is accepted.
  Nothing extra is spent: nothing was forwarded.
- **Fix:** in the helper, treat `egress.denied > 0` as provider-stopped. Add `ledger-unreadable` to `STOPPING`.
  Catch every exception in `do_POST`: deny with `body-refused` before admission, and settle as `error` after it.

### L3 (LOW): the watchdog runs longer than the wall clock, and the service may give up first

- **Code:** the watchdog loop is `while [ $n -lt "$wall" ]; do sleep 1; ...; docker container inspect ...`
  (~1398-1412). Each pass takes 1 s plus one `docker inspect`, often 0.05–0.3 s on Docker Desktop.
- **What goes wrong:**
  - A 600 s read-only run actually ends after about 630–780 s, plus admission, the proxy start (up to 15 s) and
    cleanup (`docker stop --time 3`). The service waits 720 s (`Roles.hs:286`).
  - A 1200 s write run has a 1320 s wait.
  - If the run is still going when the wait ends, the service gets `HelperNoResult`, records `RoleUncertain`, and
    sends no cancel (only `onException` sends one).

  This fails closed (the fix halts for a person), but a plain timeout becomes an unknown outcome while the run goes
  on.
- **Fix:** compare against the elapsed time (`$(( $(date +%s) - start ))`) instead of counting passes. Optionally
  run a separate `sleep "$wall"` killer as `execute_run` does.

### L4 (LOW): failed upstream requests are charged at their full reservation

- `settle` with `usage is None` charges `micro = reserve` and `out = max_tokens` for every non-2xx status (485-491),
  including 429, 529, 5xx, 400 and redirects.
- The pinned CLI retries 429 and 5xx. A few rate-limit replies can use up the run's output allowance
  (`invocation-output-tokens`) and a visible share of the budget that was never billed.
- This is safe for the cap (it over-counts), but the budget report overstates spend, and runs can be stopped
  `output-allowance-exhausted` for spend that never happened.
- If this is intended, record it in `budget-report.md`. Otherwise, settle error statuses at zero output and charge
  input only when the provider documents a charge.

### L5 (LOW): a request without `output_config` passes at the model's default effort

- `request.get("output_config", {"effort": config["effort"]})` (275) treats a missing `output_config` as the
  configured effort. Upstream, a missing effort is the model's default (`medium` on Opus 5.5 and Haiku 5.5, `high`
  on the others).
- A role can therefore run at another effort than the owner configured. The handoff §4 says no adaptive effort.
  Spend stays bounded by `max_tokens`.
- **Fix:** require `output_config == {"effort": configured}` exactly.

### L6 (LOW): the role can start more agents inside its own container

- The role image contains `/usr/local/bin/claude`, the environment holds `ANTHROPIC_BASE_URL`, and the role has
  Bash. The model can run `claude -p --bare --tools "Read Edit Bash" ...` in the background, or write its own
  loop against the proxy.
- Those agents share the same mount, so a read-only role still cannot write and the Implementer's tree is the only
  writable one. They also share the same proxy budget, request count and output allowance.
- The handoff §4 forbids "subagent or hidden multi-agent" work and requires it to be "prevented by confinement".
  Confinement here bounds such agents; it does not prevent them. Test 11 shows only that the CLI never offers a
  `Task` tool.
- **Fix:** document this as a per-invocation bound, not prevention. Optionally lower `invocation-requests` and
  remove the CLI from `PATH` after start (it cannot be removed from the image the CLI itself runs from).

### L7 (LOW): streaming usage ignores a later cache-creation count

- `StreamUsage.feed` takes later `input_tokens` and `cache_read_input_tokens` from `message_delta` (387-389) but
  not `cache_creation_input_tokens` or `cache_creation`.
- If the provider sends a larger cache-creation count in the closing delta, which happens with server-side context
  edits, the request is under-charged by that difference times the cache-write price.
- **Fix:** take all three counts and the split from the last delta when they are present, using the larger of the
  start and delta values.

### L8 (LOW): if the helper's whole process group is killed, the live run has no wall clock

- The wall clock is the background watchdog. If the helper and its children are killed (test 21 does exactly
  this), the role container and the proxy keep running until the next helper start removes them (`init_runner`,
  1170-1180). No restart may come.
- Spend stays within `invocation-requests`, the output allowance and the budget, all enforced by the proxy.
- **Fix:** give the role container its own time limit, for example `timeout "$wall"` as the container's
  entrypoint wrapper. Also give the proxy a lifetime of its own: it exits after the wall clock plus a margin.

### INFO

- **I1. DNS.** Name lookups by the role depend on Docker's embedded DNS not forwarding queries for containers that
  are only on `--internal` networks. That behaviour depends on the Docker version. Older engines whose host
  resolver is on loopback forwarded such queries from the host's namespace, which allows DNS exfiltration. Probe 5
  would catch this on the host where it runs, but there is no runtime guard or minimum Docker version. The host
  check also runs the proxy on an internal test network (`upnet`), not on the production `bridge`.
- **I2. Shared bridge.** The proxy joins the shared default `bridge` (`control-helper:1119`). Other containers
  cannot reach it only because it binds to its internal-network address. On Linux's weak-host model, a co-located
  container with `CAP_NET_RAW` (a Docker default) could in principle address that IP through the proxy's bridge
  MAC. This is impractical (its own kernel resets the TCP handshake) and budget-bounded. A dedicated egress
  network would remove it.
- **I3. Test overrides.** `LOCKSTEP_RUNNER_TEST_UPSTREAM` and `_CA` in the helper's environment would send the
  **real** key to any `host:port`, with that CA trusted. They are read only at start and only from the owner's
  environment, but the helper neither logs nor refuses them when a real provider is configured. Log them at
  start, or refuse them unless the credential is clearly synthetic.
- **I4. Reservation assumption.** The reservation assumes "no more tokens than bytes, plus 4096". This is
  unverified for replayed thinking blocks, whose encrypted or opaque payloads may decode to more tokens than their
  bytes. Settling records the true cost, so an overrun is bounded by the in-flight requests.
- **I5. Long-context prices.** They are owner-configured percentages with one threshold. Haiku 5.5 changes price at
  100K tokens, five times over. The configuration must say so; nothing checks the configuration against the
  pricing basis.
- **I6. Exfiltration to the provider.** Anything in the tree can be sent to the provider. This is inherent to a
  live run and not a finding.
- **I7. Image pinning.** The proxy and CLI image pins the base image digest and the CLI's SHA-512, but `apt-get
  install python3 git ca-certificates` is unpinned, so the proxy's interpreter can change between builds.
- **I8. Startup-only configuration.** The provider line and `CLAUDE_CODE_MAX_OUTPUT_TOKENS` are fixed when the
  helper starts. Changing the configuration later fails closed (`model-refused`, `max-tokens-refused`) until a
  restart. The provider line sits in the service-writable runner directory, but the proxy enforces the model, so
  the line is advisory only.

## Checked and holds

- **No route out for the role.** The role container is on its run's `--internal` network only, with no
  capabilities and no new privileges, and runs as the invoking user. It cannot add routes or send raw packets, so
  it cannot use the dual-homed proxy as a gateway even if the kernel forwarded. Probe 5 confirms this in the test
  topology.
- **Bind order.** The proxy binds to `gethostbyname(gethostname())` while the internal network is its only
  interface, writes `.ready`, and only then joins the egress network. The role starts only after that.
- **No request smuggling or redirect.**
  - The upstream request is built from scratch: fixed host and path, the proxy's own `x-api-key`, an
    `anthropic-version` checked by regex, and the allowlisted beta features.
  - `Host`, absolute URLs, `CONNECT`, `Authorization` and other headers are never forwarded.
  - Every response sets `connection: close`, so pipelining or keep-alive cannot carry a second request.
  - A 3xx answer is refused and its `Location` is never passed on.
- **The upstream's TLS is verified** with the default context and the fixed host name.
- **The credential stays with the proxy.**
  - It is checked (owned, 0600, not a link, `sk-ant-` shape) by the helper and again by the proxy.
  - It is mounted read-only into the admission container and the run's proxy only. It never appears in argv, the
    environment, `docker inspect` (paths only), the ledger, summaries, results or logs.
  - `log_message` is silenced, the proxy's output goes to `--log-driver none`, and refusal bodies carry codes only.
  - It is removed with the proxy. The role sees a placeholder key, and `--bare` reads no stored login.
- **Fields that reach results are sanitised.** Summary values are copied into the signed result only for known
  keys, through `tr -cd`. Paths are reduced to `[A-Za-z0-9/?=._-]`, so a crafted path cannot inject a summary
  line or a result field.
- **Ledger durability and ownership.**
  - The ledger is append-only, written with `O_APPEND|O_NOFOLLOW` and `fsync`, and lives in the helper's 0700
    directory.
  - It is mounted read-write only into the run's proxy and read-only into admission. Neither the service (whose
    container mounts only `runner/`) nor the role mounts it.
  - A corrupt or partial line makes the ledger unreadable, which refuses everything (fail-closed).
  - A never-settled reservation stays charged across restarts (test 20).
- **Reservation math.**
  - Integer arithmetic with `ceil`.
  - The budget, token, output and request checks and the reservation write happen under one lock, and open
    reservations count against the budget, so concurrent requests cannot oversubscribe it.
  - Usage that cannot be read (missing, malformed, a stream without `message_stop`, server-tool use, a body too
    large to parse, a broken client pipe) settles at the reservation and stops the run.
- **Outcome determination.**
  - A missing summary, a proxy that was never ready, or a proxy gone before the role ends gives
    `provider-stopped egress-failed`.
  - `admitted ≠ settled` gives `usage-unknown`.
  - Cancellation and timeout take precedence.
  - The service maps `provider-stopped` to `RoleFailed "provider-stopped <code>"` and never reads that run's
    `result.json`. The code is validated (`HelperRunner.hs:252-257`).
- **No automatic replay.** `HelperRefused` and `ProviderStopped` give `RoleFailed`; an unknown outcome gives
  `RoleUncertain`. Neither is retried by the engine (integration tests L5-B, L5-D, L5-E).
- **Role confinement.**
  - The tree is read-only for every role but `run-live-write` (the Implementer's only).
  - Protected tests are nested read-only binds, and the engine checks them again (`Engine.hs:1341, 1406`).
  - `active_pid` allows one run at a time (test 18).
  - Verification and engine commands use `ProfileVerify`, which `liveProfile` leaves offline (`Engine.hs:954,
    1006`), so model-written checks never get the proxy.
- **Adapter argv.** It matches the fixture. There is no fallback model, MCP server or kept session. The same tools
  are given to every role, and the mount decides who may write.
- **Cleanup.**
  - The role container, the proxy and the network are removed after every run.
  - `init_runner` removes leftover containers, proxies and networks at start.
  - Runs that never ended are reported `interrupted`.
