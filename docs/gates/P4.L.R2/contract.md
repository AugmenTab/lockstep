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
the tool calls the upstream issued — and send requests of **that same conversation** in the CLI's place, while the CLI
waits for the tool call that started it. A second conversation alongside the first is never admitted.

*Correction (writer, before the owner's decision was acted on):* this section first said the proxy "would admit it
once". That was not established. The rule admits every request that answers the latest tool calls, so an
impersonator inside one tool call can continue the conversation for **as many requests as the run's own allowances
permit** (requests, output tokens, budget, wall clock), not one. And if the impersonator ends on a final answer (no
tool calls), the CLI's own next request answered no outstanding call and was admitted: the CLI resumed undetected
(`check-live-impersonation` baseline, §9). The second gap is closed by R2-H2b below; the first is reported to the
owner as a **blocking discrepancy** with their condition 1.

Smallest correction, for the owner's decision (not built here): run the CLI and its tools as different users in the
container (a small wrapper and image change), so no tool process can read the CLI's memory. It touches the provider
image and the helper's run command, not the Supervisor or the engine.

## 9. Addendum — the owner's H2 decision and its adversarial regression (2026-10-29)

The owner (in the session) accepted the H2 limitation **only for the initial, attended, disposable-repository smoke**,
on conditions: (1) a second independent conversation is refused, and impersonating the next request causes the real
CLI's subsequent request to be refused and the invocation to stop with no accepted result; (2) impersonated requests
use the run's own durable budget, request allowance and reservations; (3) a stopped invocation cannot produce an
accepted implementation, review or Supervisor commit, and its workspace changes stay untrusted; (4) the residual risk
documented accurately; (5) a future confinement-hardening item recorded (process-memory isolation between the CLI and
the processes running repository code: ptrace restrictions, `process_vm_readv`, `/proc/<pid>/mem`, privilege
separation; disabling `ptrace` alone is not assumed sufficient); (6) no extension to arbitrary or untrusted
repositories, unattended runs or production use. "If the described one-request bound or fail-closed outcome cannot be
demonstrated, report the discrepancy as a blocking finding."

| # | Decision |
|---|---|
| R2-H2b | **A conversation that has ended admits nothing more.** After a complete answer with no tool calls (the turn's end), any further request of the run is `conversation-refused`. The CLI in print mode exits after its final answer; a request after it is not the CLI's. (A CLI that continues after a final answer for another reason — a `max_tokens` stop — then stops the run: fail-closed.) |

Verification (frozen with this addendum):

| File | sha256 | Covers |
|---|---|---|
| `scripts/lib/check-live-impersonation` | `1cb2d83c6c5edb3d85bde8ff75c515465b952b02037aacb7f69d83dacee52c23` | The real helper (offline mode), the real CLI, the agent stand-in; an impersonator in the Implementer's Bash call continuing the run's conversation 1 time (a tool call left open) and 2 times (ending on a final answer): the CLI's own next request refused and the run `provider-stopped conversation-refused`; no answer written; the impersonated requests reserved and settled in the run's own ledger and counted in its own request allowance; nothing else sent; and the owner's one-request bound as an explicit expectation |

Baseline against the implementation before R2-H2b (`.local/p4lr2-impersonation-baseline.log`): impersonating once —
all hold; impersonating twice, ending on a final answer — **the CLI resumed undetected** (5 requests sent, an answer
written) and **two impersonated requests were admitted** (the bound). One test fault fixed before the freeze (a
missing `]`).

Result with R2-H2b (`.local/evidence/live-impersonation-20261029t202500z/results.txt`): **12 of 13**. Conditions 1
(fail-closed: the CLI's next request refused, the run stopped, no answer), 2 (the run's own ledger and request
allowance; nothing else sent) and 3 (a `provider-stopped` run is `RoleFailed` in the service, never an answer:
`Roles.runPrepared`; the fix halts for a person: C-P4.L LiveAdapterTest L5-B) hold. **The one-request bound does
not hold** (`impersonated-2 200`): an impersonator is bounded by the run's own allowances, not to one request. Per
the owner's instruction this is reported as a **blocking finding** for the smoke (the packet), not built around:
closing it needs the process-memory isolation of the owner's hardening item 5.

## 10. Verification record (the final implementation, before full qualification)

| Check | Result | Evidence |
|---|---|---|
| `check-live-boundary` (H1, H2, H3) | **83/83** | `.local/evidence/live-boundary-20261029t202525z/results.txt` |
| `check-live-impersonation` (§9) | **12/13** — the one-request bound fails (blocking, reported) | `.local/evidence/live-impersonation-20261029t202500z/results.txt` |
| `check-live-proxy` (amended A-P4.L.R1-1) | **21/21** | `.local/evidence/live-proxy-20261029t202625z/results.txt` |
| `check-live-runner` (amended A-P4.L-1) | **84/84** | `.local/evidence/live-20261029t202647z/results.txt` |

After the R2-H1 correction (§11), the final proxy:

| Check | Result | Evidence |
|---|---|---|
| `check-live-concurrency` (§11) | **17/17** | `.local/evidence/live-concurrency-20261029t204313z/results.txt` |
| `check-live-boundary` | **83/83** | `.local/evidence/live-boundary-20261029t204352z/results.txt` |
| `check-live-impersonation` | **12/13** — the one-request bound (blocking, reported) | `.local/evidence/live-impersonation-20261029t204455z/results.txt` |
| `check-live-proxy` (amended) | **21/21** | `.local/evidence/live-proxy-20261029t204513z/results.txt` |
| `check-live-runner` (amended) | **84/84** | `.local/evidence/live-20261029t204530z/results.txt` |

## 11. Addendum — the narrow independent review (R2-H1) and its correction

The review `docs/reviews/phase-4-live-hardening-review-2026-10-29.md` (independent, read-only, `f5b86a6..da7d70a`):
**one HIGH, no MEDIUM, five LOW, three INFO.**

**R2-H1 (HIGH), confirmed by the writer and by a regression:** the conversation rule kept only the latest answer's
tool calls and nothing about requests in flight, so two requests answering the same tool calls (or two identical
openings) sent at the same time were both admitted; whichever answer finished last set the state. A process that can
read the CLI's memory could therefore run a second conversation turn alongside the CLI's own, each turn, undetected.
This contradicted §6 ("a second conversation alongside the first is never admitted") and the §9 statement that the
owner's condition 1 held.

| # | Decision |
|---|---|
| R2-H1a | **One conversation request in flight a run.** A request of the run's conversation is admitted only when no other is in flight; a second one at the same time is `conversation-refused` (the run stops). |
| R2-H1b | **Each answer's tool calls are answered once.** Admitting a request that answers the latest tool calls (or the opening) uses them up; another request answering them is refused. They are released only if the request ends without a complete answer (a provider error or a broken stream), so the CLI's retry is admitted. |
| R2-H1c | **The state moves before the answer is delivered** (the review's R2-L2): the proxy holds back the answer's last bytes until it has settled the request and recorded the new tool calls, so the CLI's immediate next request is never refused for arriving early. |

Verification (frozen with this addendum, commit `38bcf53`):

| File | sha256 |
|---|---|
| `scripts/lib/check-live-concurrency` | `ac19ff3d7aec9ecf761d8c0d1d1fbe14b7fed7905c88378c8f01d3d5cb48b666` |
| `scripts/lib/live-continuation-probe` | `0d31d7abbb9c41ccc4002d5327c8789f907be4f5451bccf57f240c66403b8f20` |
| `scripts/lib/live-upstream-tools` | `f33776fb503386dd845bbc4365096b427c74196222354d5886eb1838effe0341` |

Covers: C1 ten fast continuations of the run's own conversation admitted (no false stop); C2 two continuations of the
same tool call at once — one admitted, the other refused, the run stopped, only two requests upstream; C3 two identical
openings at once — likewise; C4 an answered tool call answered again — refused; C5 a tool call never issued, after a
real opening — refused (the review's R2-L5 coverage gap); C6 the opening retried after the provider's 529 — admitted.

Baseline against `da7d70a` (`.local/p4lr2-concurrency-baseline.log`): **6 failures, exactly C2 and C3** (both
concurrent requests admitted and sent); everything else held. A first baseline had one test fault, corrected before
the freeze: each case's proxy was left running under the same network alias, so probes reached an earlier, stopped
proxy (the check now removes it).

The review's LOW and INFO items, dispositioned:

| Finding | Disposition |
|---|---|
| R2-L1 (a refusal's stop is recorded just after the response is chosen, not under the admission lock) | **Recorded.** The request admitted in that window passes every check, including the conversation rule, which R2-H1a now serializes; it is not a second agent's. |
| R2-L2 (the state moves after the answer reaches the client) | **Fixed** (R2-H1c). *Corrected:* C1 also passed before the fix, so no frozen test fails without R2-H1c; the fix rests on the code and on the confirming review (below), not on C1. |
| R2-L3 (offline mode's internal-network check only at start) | **Recorded.** Replacing the named network between runs needs control of the operator's Docker; offline mode is for the host checks only. |
| R2-L4 (a timeout or cancellation hides the proxy's stop reason in the result) | **Recorded.** The outcome is never an answer in either case; the stop stays in the run's summary in the ledger directory. |
| R2-L5 (coverage gaps) | **Partly fixed**: C4, C5 and concurrency covered here; the stand-in's fixed tool ids remain (they model the memory-reading impersonator, by design). |
| INFO items | Recorded in the review; no change. |

### The confirming review of the correction

`docs/reviews/phase-4-live-hardening-fix-review-2026-10-29.md` (independent, read-only, `da7d70a..7018df9`):
**R2-H1: CLOSED**; no HIGH, no MEDIUM, two LOW, four INFO.

| Finding | Disposition |
|---|---|
| LOW-1 (an unexpected exception after admission leaves the run in flight for good) | **Recorded.** Fail-closed: every later request of the run is refused and the run stops; never a bypass. |
| LOW-2 (an error answer's headers are sent before it is settled; a client that retries within milliseconds could be stopped) | **Recorded.** Fail-closed (a false stop of the run, which then halts for a person). |
| INFO-1 (C1 does not test R2-H1c) | **Corrected** in the R2-L2 row above. |
| INFO-2 – INFO-4 | Recorded; no change. The image used for the evidence was built from the working tree identical to `7018df9`. |

Full Mac qualification at `7018df9`: `scripts/check --integration` all six steps PASSED — unit 870/870, integration
571/571, the guard's sentinel log empty after the integration step (`.local/p4lr2-check-mac.log`). The Linux clean
clone, `check-runner`, `check-runner-paths` and the stress test are held at the owner's word (2026-10-29: "don't
start Linux right away").

## 12. Allowed paths

Changed: `scripts/runner/provider/egress-proxy`, `scripts/control-helper`, the files of §3, `docs/gates/P4.L.R2/**`,
`docs/gates/P4.L/**` (the smoke proposal's configuration steps), `docs/gates/C-EXEC/**`, `docs/reviews/**`,
`docs/OPERATOR_GUIDE.md`, `docs/governance/DECISION_REGISTER.md`; with authorization only, the amended checks of §5.

## 13. Budget, stop, rollback

At most 3 implementation attempts per failing frozen check. Rollback: revert the commits and rebuild the image.
