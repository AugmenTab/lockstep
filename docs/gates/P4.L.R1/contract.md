# Contract — P4.L.R1 Remediation of the independent review of C-P4.L

- Contract ID: `C-P4.L.R1@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-04_update3.md` §10 steps 6–7 (an independent review of the new integration; a
  confirmed HIGH or MEDIUM blocking a live trial is resolved); the review
  `docs/reviews/phase-4-live-integration-review-2026-10-29.md` (`b0b922d..c7a6d54`: no HIGH, two MEDIUM, eight LOW,
  eight INFO).
- Writer: the single writing agent (Implementer, manual). Scope: M1, M2 and the LOW items that bear on the budget's
  or the run's soundness (L1, L2, L3, L5, L7) and one INFO item (I3); the rest dispositioned in §5.

## 1. The findings, as checked by the writer

- **M1 confirmed.** The proxy checked `json.loads(body)` and forwarded `body`. Python keeps the last of duplicate keys;
  a provider whose parser keeps the first would act on a value never checked (another model, a provider-side tool).
- **M2 confirmed.** Top-level fields were refused by a short denylist (`mcp_servers`, `container`); any other field,
  including one that changes the price (regional inference, a service tier), was forwarded, and the reservation and
  the settlement used the configured prices.
- L1, L2, L5, L7 confirmed in the code; L3 confirmed (the live watchdog counted passes of a loop that also runs
  `docker inspect`); I3 confirmed (the test overrides were silent).

## 2. Decisions

| # | Decision |
|---|---|
| R1-M1 | **The checked document is what is sent.** The body is parsed with duplicate keys refused (`body-refused`) and a nesting or size the parser cannot take refused (`body-refused`); the proxy sends its own serialization of the checked document, never the client's bytes; the reservation is computed on what is sent. |
| R1-M2 | **Only the fields the pinned CLI sends** (observed, 2.1.312): `model`, `max_tokens`, `messages`, `system`, `tools`, `stream`, `output_config`, `thinking`, `context_management`, `metadata`. Any other top-level field is refused (`field-refused`). `output_config` must be exactly `{"effort": <configured>}`; `thinking` an object whose `type` is `adaptive`, `enabled` or `disabled` with only `type`, `display` and `budget_tokens`; `metadata` at most `{"user_id": text}`. |
| R1-L1 | A proxy refuses to serve a run name already in the ledger (`run-reused`): the ledger's reservations are keyed by run and request, so a reused name could otherwise hide an unsettled one. |
| R1-L2 | Every refusal stops the run, including `ledger-unreadable` and a ledger that cannot be written (`ledger-unwritable`). |
| R1-L3 | The live watchdog's wall clock is a deadline in seconds, not a count of loop passes. |
| R1-L5 | A request without `output_config` is refused (`effort-refused`): the configured effort is required, never a default. |
| R1-L7 | The final `message_delta` usage, when it reports them, replaces the cache-write counts (and their split) as well as input, cache-read and output counts. |
| R1-I3 | A helper started with a test override says so in its log (`TEST OVERRIDE`), once, at start. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-proxy` | host: real Docker, the real proxy of the provider image, a recording stand-in upstream | R1-M1 (a loosely written request reaches the upstream re-serialized; a model or tools written twice refused, nothing sent); R1-M2 (a regional-inference field and a service tier refused); R1-L5 (no effort refused); a body nested 100 000 deep refused and the proxy still answering; the run's first refusal is its stop; R1-L1 (a run name already used does not start; one `invocation` line); R1-L2 (an unreadable ledger: nothing sent, `ledger-unreadable`, the run stopped); R1-L7 (the settlement counts the cache write reported only in the final message: `settle … 3858 1025 5 known 10 5 1000 0 10 200`); the credential in no kept file |
| `scripts/lib/live-proxy-probe`, `scripts/lib/live-upstream-record` | test tools | raw requests to the proxy; the recording upstream |

The frozen `scripts/lib/check-live-runner` (C-P4.L) must still pass (it covers the timeout with the new deadline,
R1-L3, and every earlier proxy and helper behaviour).

## 4. Freeze record

- Frozen 2026-10-29 by the single writing agent (Implementer, manual), on `phase-4` after `c7a6d54`.

  | File | sha256 |
  |---|---|
  | `scripts/lib/check-live-proxy` | `0a7cbb01c71aecab05a2021c3bdbc9babafeb565736f5de6d2d1878f0b67f96d` |
  | `scripts/lib/live-proxy-probe` | `41cab8b0bceedf8e19d18001d9fc40fe5a9c5210cfb7871cfadb36f9e2a0bfc0` |
  | `scripts/lib/live-upstream-record` | `d1da6bfcf5c4aa76ca978503894312e14f9d3cf639146bf48f2e312267223c8d` |

- Baseline against the image built from `c7a6d54` (no stubs: the check calls only the existing proxy;
  `.local/p4lr1-baseline.log`): **15 fail, each for its finding's reason**: the client's bytes forwarded as sent; the
  final message's cache write not charged (`settle … 0 0 …`); a model and tools written twice, a regional-inference
  field, a service tier, a request without effort all forwarded; a 100 000-deep body dropping the connection
  (`RecursionError`); the first refusal not the run's stop; a reused run name served again (two `invocation` lines);
  an unreadable ledger not stopping the run. 5 pass and held before (a valid request answered; the proxy answering
  after refusals; an unreadable ledger already refusing the request and sending nothing; no credential kept). A
  first baseline run had one test fault, corrected before the freeze: a restarted run name found its first proxy's
  ready file (the helper removes it before every start; the check now does too).

## 5. Dispositions of the rest

| Finding | Disposition |
|---|---|
| L4 (failed requests charged at their full reservation) | **Kept, by design** (budget report §3.4): safe for the cap; retries can stop a run early, and the stop says so. |
| L6 (the role can start the CLI again inside its own container) | **Recorded; bounded by confinement.** A second CLI process shares the run's one container, mounts (read-only for every role but the Implementer), its proxy, the per-run request and output allowances and the budget; it cannot get another workspace or another network. The handoff's requirement is met by confinement: no additional writable workspace exists. The proxy also refuses any request offering an agent tool. |
| L8 (helper killed with its children: no wall clock until it restarts) | **Recorded.** The run's spend stays within the proxy's per-run allowances and the budget; a restarted helper removes the run, its proxy and network and reports it interrupted (C-P4.L check 21). |
| I1 (DNS isolation depends on the Docker version; the production `bridge` egress not exercised) | **Recorded; an evidence item of the smoke** (the network probe of `check-live-runner` is repeated on the operator's Docker before the smoke). |
| I2 (the proxy shares the default bridge) | **Recorded.** The proxy listens only on the run's internal network (it binds to that interface before joining the bridge); other containers on the bridge reach no listening port. |
| I4 (bytes-per-token for replayed thinking blocks) | **Recorded** with the budget report's assumption 1; thinking signatures are base64 (more bytes than tokens). |
| I5 (Haiku's long-context price) | **Recorded**: the owner's configuration names every price. |
| I6 (data sent to the provider) | **Inherent** to a live run; recorded. |
| I7 (the image's `apt` packages not pinned) | **Recorded**; the CLI itself is pinned by SHA-512, the base image by digest. |
| I8 (provider settings read at helper start) | **Recorded** in the operator guide: change the configuration, restart the helper. |

## 6. Allowed paths

Changed: `scripts/runner/provider/egress-proxy`, `scripts/control-helper`, the files of §3, `docs/gates/P4.L.R1/**`,
`docs/gates/P4.L/**`, `docs/gates/C-EXEC/**`, `docs/reviews/**`, `docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen check. Rollback: revert the commits and rebuild the image.
