# Contract — P4.L.R2 Final live-provider hardening: terminal refusals, one writing agent, test overrides

- Contract ID: `C-P4.L.R2@v1`
- Status: **FROZEN** (§4); amendments A-P4.L.R1-1 and A-P4.L-1 **PROPOSED, awaiting the owner** (§5)
- Authority: `.local/plans/phase-04_update4.md` (sha256 `bdf52c60…cfd7e1f`), H1–H3; DG-17; the architectural
  decision "one production-code-writing Implementer per canonical repository; no parallel coding swarm".
- Writer: the single writing agent (Implementer, manual). Basis: `phase-4` at `f5b86a6` (candidate `d13ac33`), clean.
- Scope: H1, H2, H3 only. No provider call, no real credential, no installation, no change to the Supervisor, the
  engine, the adapter's interface or the number of Implementers.

## 1. The findings, as checked against `d13ac33` (not assumed from the patch)

| # | Finding | Reachable at `d13ac33`? | Evidence |
|---|---|---|---|
| H1 | A refusal is recorded as the run's stop but does not stop admission | **Yes.** `admit_request` never reads the stop; after `body-refused`, `field-refused`, `effort-refused`, `requests-exhausted` or `ledger-unreadable` a later valid request was admitted and reached the upstream | baseline `.local/p4lr2-baseline.log` (H1 rows); the frozen `check-live-proxy` itself expected `200` after a refusal |
| H2 | One writable workspace, but not one writing agent | **Yes, demonstrated.** From the Implementer's Bash tool, a second Claude CLI (`claude …` with the inherited environment, or `/usr/local/bin/claude` with the proxy named) ran its own conversation through the run's proxy and **rewrote `calc.py`** (`return 'NESTED'`); a direct Python client opened a new conversation and was answered (200). The Bash tool's environment holds `ANTHROPIC_BASE_URL` and the placeholder key; the image holds the CLI at `/usr/local/bin/claude`; `python3` can speak HTTP. No built-in agent tool is offered (`--bare --tools "Read Edit Bash"`; the proxy refuses `Task`/`Agent`). | `.local/p4lr2-h2-investigation.txt` (the real CLI, the committed helper, a stand-in that plays a second agent's turns) |
| H3 | Test overrides from the environment usable with the production credential | **Yes.** `LOCKSTEP_RUNNER_TEST_UPSTREAM`, `…_UPSTREAM_CA`, `…_EGRESS_NETWORK` were honoured with `DIR/provider/credential`, the production key's path; only logged | baseline H3 rows (live runs on with each override) |

Also found while investigating H2: in the Docker VM `kernel.yama.ptrace_scope` is 0, so a process in the role's
container can read the CLI's own memory (`/proc/1/mem`, `/proc/1/environ`): see §6.

## 2. Decisions

| # | Decision |
|---|---|
| H1 | **A terminal refusal ends the run's admission.** Terminal: every proxy refusal (the request's own checks, the run's and the budget's limits, an unreadable or unwritable ledger, a refused conversation) and a stop the proxy records itself (unknown usage, the provider refusing the key, a redirect). Not terminal: the provider's own error answers (429, 5xx, other 4xx), passed back and charged at their reservation, which the CLI may retry. Once a stop is recorded, every later request is refused: by its own check if it fails one, otherwise `run-stopped`; nothing more is reserved or sent. Requests already admitted settle by the existing rules. The first stop stays the run's stop; the helper reports the run `provider-stopped <that stop>`; a run name is served once (C-P4.L.R1 R1-L1). |
| H2 | **One conversation a run, at the only door to a model.** The proxy admits one opening request a run (no assistant turn in it); it may be sent again only unchanged (a retry) and only until it has been answered. Every later request may name only tool calls the upstream issued in this run, and must answer all tool calls of the latest complete answer. Anything else (a second CLI, a direct client, a forged or replayed history) is `conversation-refused`, which by H1 ends the run. The tool calls are read from the upstream's own answers (streamed or not); only a complete answer whose usage is known moves the conversation on. Ordinary subprocesses (compilers, test runners, `git`, `python3`) are untouched: they reach no model. |
| H3 | **Two explicit modes, decided at helper start.** *Production*: no `DIR/provider/offline-test`; the upstream `api.anthropic.com:443` with the system's CAs, the egress network Docker's bridge, the key `DIR/provider/credential`. *Offline test*: an owner-made `DIR/provider/offline-test` (0600, owned, exactly `lockstep-offline-test 1`, `upstream HOST:PORT`, `ca /ABSOLUTE/FILE`, `egress-network NAME`), an egress network that Docker reports **internal** (no route out at all, so no key of any kind can leave the machine), and the key `DIR/provider/offline-credential`. Refused at start, before any key is read, live runs off, the reason in the log without any key: `test-override-refused` (any of the three environment variables, in either mode), `offline-test-with-credential` (`DIR/provider/credential` present in offline mode), `offline-network-not-internal`, `offline-test-invalid`. The log names the offline mode (`live runs on (OFFLINE TEST: …)`). Not based on any key's name or prefix. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-boundary` | host: real Docker; the real proxy with a recording stand-in; the real helper and the real Claude Code CLI with an agent stand-in | H1 for malformed JSON, a duplicated field, an unsupported field, an effort violation, an exhausted limit and an unreadable ledger: a valid request first (200), the refusal, a valid request after (`run-stopped`), no further upstream request, the first stop kept, one reservation settled; a fresh run still answered. H2 at the proxy: a second opening, the opening again after its answer, a forged history — refused, nothing sent, the run stopped `conversation-refused`. H3: production accepted (no run submitted in it); production with each environment override and both refused; offline with the production key present, on a network that can reach out, or with an environment override, refused; each refused configuration sends nothing; explicit offline with a synthetic key accepted and named. H2 through the CLI (offline mode): the Implementer edits the source; a read-only role cannot; only `Read`, `Edit`, `Bash` offered; a second CLI by name, a second CLI by absolute path with the proxy named, and a direct client each end the run `provider-stopped conversation-refused`, reach no upstream and change nothing; ordinary tooling (`py_compile`, `git`, `python3`) works and the run completes; the synthetic key in no kept file |
| `scripts/lib/live-standin-agent`, `scripts/lib/live-conversation-probe` | test tools | the agent stand-in (plays the run's turns, and a second agent's); conversation requests to the proxy |

Safety of the check itself: a run is submitted to a refused configuration only while live runs are off, and the CLI
cases only after the helper names the offline mode, so even against the old code no request can leave the machine.
The frozen `check-live-proxy` and `check-live-runner` conflict with H1 and H3: their amendments are §5.

## 4. Freeze record

- Frozen 2026-10-29 by the single writing agent (Implementer, manual), on `phase-4` after `f5b86a6`.

  | File | sha256 |
  |---|---|
  | `scripts/lib/check-live-boundary` | `24a192c660673faa8f707f30546352d4311ac3b5b2a0f5e21ec326d481c3defc` |
  | `scripts/lib/live-standin-agent` | `c8663db599dfdb0beea9274bfc8f112661e9f7ddac4a2ef8a65e60c6581d06f4` |
  | `scripts/lib/live-conversation-probe` | `6790a1ddd18c57db5f7a7b52c8d271c42086e88f233b634ba2fa1da67b5af1ec` |

- Baseline against `d13ac33` (no stubs; the check calls the existing proxy and helper;
  `.local/p4lr2-baseline.log`): **39 failures, each for its finding's reason**: a valid request after each terminal
  refusal admitted and sent upstream; a second opening, a re-sent opening and a forged history admitted; every
  environment override accepted with the production key; the explicit offline mode unknown. The CLI part of H2 does
  not run at baseline by design (no offline mode, so no run is submitted); its baseline is the investigation
  (`.local/p4lr2-h2-investigation.txt`: a second CLI rewrote `calc.py`). A first baseline had one test fault, fixed
  before the freeze: the stand-in's certificate named only `standin`, not `recorder`.
- Trial (the implementation kept in `.local/p4lr2-impl/`): **83 of 83**
  (`.local/evidence/live-boundary-20261029t200051z/results.txt`).

## 5. Amendments to frozen checks (the owner's authorization required)

See `docs/gates/P4.L.R2/amendments.md`: A-P4.L.R1-1 (`check-live-proxy`, H1) and A-P4.L-1 (`check-live-runner`,
H3), with the original digests, the exact diffs, the new digests, why the original expectations contradict the
stopping invariant and the explicit-mode rule, and RED/GREEN trials. The frozen files are unchanged until authorized.

## 6. What H2 establishes, and the limitation that remains

Of the three properties the handoff separates: (1) one Supervisor-authorized Implementer invocation, and (2) one
writable repository workspace, were already established (the engine, C-P4.2 mounts); (3) **one code-writing agent**
is now enforced at the only route to any model: a run's proxy admits one conversation, and any second conversation
started inside the container — a second CLI by any path, a background session, a direct client, a forged or replayed
history — is refused before it reaches a model, and ends the run.

**Remaining limitation (stated plainly, not claimed prevented):** a process inside the role's container can read the
CLI's own memory (`ptrace_scope` 0 in the Docker VM; same user). Such a process could copy the run's conversation —
the tool calls the upstream issued — and send the next request of **that same conversation** in the CLI's place. The
proxy would admit it once; the CLI's own next request then no longer answers the latest tool calls and is refused, so
the run stops `conversation-refused` and nothing it produced is accepted (a stopped run halts for a person; the
Supervisor commits nothing). A second conversation alongside the first is never admitted. Reaching even this needs the
model to write and run a memory-scraping program inside its own run.

Smallest correction, for the owner's decision (not built here): run the CLI and its tools as different users in the
container (a small wrapper and image change), so no tool process can read the CLI's memory. It touches the provider
image and the helper's run command, not the Supervisor or the engine.

## 7. Allowed paths

Changed: `scripts/runner/provider/egress-proxy`, `scripts/control-helper`, the files of §3, `docs/gates/P4.L.R2/**`,
`docs/gates/P4.L/**` (the smoke proposal's configuration steps), `docs/gates/C-EXEC/**`, `docs/reviews/**`,
`docs/OPERATOR_GUIDE.md`, `docs/governance/DECISION_REGISTER.md`; with authorization only, the amended checks of §5.

## 8. Budget, stop, rollback

At most 3 implementation attempts per failing frozen check. Rollback: revert the commits and rebuild the image.
