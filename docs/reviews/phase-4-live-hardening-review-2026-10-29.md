# Review — P4.L.R2 live hardening (H1 terminal refusals, H2 one writing agent, H3 explicit modes)

- Reviewer: independent, read-only (did not write this code; nothing built, run, edited or committed).
- Date: 2026-10-29. Range: `f5b86a6..da7d70a` on `phase-4`.
- Inputs: `scripts/runner/provider/egress-proxy`, `scripts/control-helper`, `scripts/lib/check-live-boundary`,
  `check-live-impersonation`, `live-standin-agent`, `live-conversation-probe`, amended `check-live-proxy` and
  `check-live-runner`; `docs/gates/P4.L.R2/{contract,amendments}.md`; evidence `live-boundary-20261029t202525z`
  (83 PASS / 0 FAIL), `live-impersonation-20261029t202500z` (12/13), `live-proxy-20261029t202625z` (21/0),
  `live-20261029t202647z` (84/0); `.local/p4lr2-h2-investigation.txt`.

## Counts

| Severity | Count |
|---|---|
| HIGH | 1 |
| MEDIUM | 0 |
| LOW | 5 |
| INFO | 3 |

## Findings

| ID | Sev | Where | Claim broken |
|---|---|---|---|
| R2-H1 | HIGH (conditional: needs the already-accepted in-container memory read) | `egress-proxy:585-615, 761-764` | "impersonating causes the real CLI's subsequent request to be refused" (owner condition 1); "a second conversation alongside the first is never admitted" (contract §6); OPERATOR_GUIDE "the CLI's next request then stops the run" |
| R2-L1 | LOW | `egress-proxy:555-583, 549-553, 693-695, 714-719` | "once a stop is recorded every later request is refused" holds, but a refusal decision and its stop record are not atomic |
| R2-L2 | LOW | `egress-proxy:742-764` | the legitimate CLI is never falsely stopped (conversation state advances after the bytes reach the client, outside the critical section) |
| R2-L3 | LOW | `control-helper:1266-1269, 1421-1433` | offline mode "no route out at all": the network's internal flag is checked once, at helper start |
| R2-L4 | LOW | `control-helper:1512-1535` | "the helper reports the run `provider-stopped <that stop>`" |
| R2-L5 | LOW | `check-live-boundary:184-203`, `live-standin-agent:117-141` | test coverage of the H2 rule's branches and of real-API conditions |
| R2-I1 | INFO | `egress-proxy:585-615` | false stops on auto-compaction (not mentioned) / `max_tokens` (mentioned) |
| R2-I2 | INFO | amended `check-live-runner` | production-path credential cases no longer exercised end to end |
| R2-I3 | INFO | contract §9/§10, evidence | the 12/13 "one-request bound" failure is reported accurately |

## Details

### R2-H1 (HIGH, conditional) — a concurrent fork of the conversation evades the fail-closed rule

**Claim.** Contract §6: "A second conversation alongside the first is never admitted." §9: condition 1 ("impersonating
… causes the real CLI's subsequent request to be refused and the invocation to stop with no accepted result")
"hold[s]". OPERATOR_GUIDE: "the CLI's next request then stops the run and nothing is accepted".

**Mechanism.** `check_conversation` (585-605) checks a request against `self.latest`, but admission records nothing
about the conversation. `latest` only changes in `answered()` (607-615), called when a response completes (763-764).
So while one request answering `latest` is in flight, **any number of other requests answering the same `latest`
are admitted**, and whichever answer finishes **last** decides `latest`. Nothing tracks pending requests or "this
`latest` has been answered once".

**Scenario** (the precondition the owner already accepted: a same-user process in the role's container reads the
CLI's memory, `ptrace_scope` 0, demonstrated in the H2 investigation):
1. A repository script started by an earlier tool call (e.g. a test's conftest) leaves a detached daemon. It reads the
   current tool-call id `t1` from `/proc/1/mem`.
2. The CLI's tool returns; the CLI sends `R_c` answering `t1`; admitted (latest = {t1}); the model works for seconds.
3. During that window the daemon sends `R_i`: any content of its own choosing (e.g. "rewrite calc.py") wrapped in a
   history whose tool blocks name only `t1` (`used ⊆ issued`, `{t1} ⊆ answered`, has an assistant turn). Admitted.
   It asks for a short answer with one tool call, so it usually completes first: `latest = {tX}`.
4. `R_c` completes: `latest = {tY}` (the CLI's). The CLI's next request answers `tY` — **admitted; the CLI resumes
   undetected.** The daemon executes `tX` itself (it writes the tree; the Implementer mount is writable).
5. It repeats on every later CLI turn (fabricating tool_results for the CLI's current ids, read from memory, plus its
   own issued ids), for as long as the run's allowances last. If it mistimes once (its answer completes last), the
   run stops — fail-closed — but the attacker controls the odds (short prompt, small `max_tokens`).

Result: a second, model-driven writing agent runs alongside the CLI, the run is not stopped, `result.json` is written
by the CLI normally, and the invocation can produce an accepted implementation (condition 3 relies on the stop).
The documented limitation ("then the CLI's next request stops the run") is **not the only gap**: it holds only for
sequential impersonation inside the tool call.

**Evidence.** `admit_request` 572 calls `check_conversation` and returns; no pending marker. `answered` 612-613
overwrites `latest` with the last-completing answer's ids; `issued` only grows. No check that a request's
`answered` equals the latest set exactly once.

**Coverage.** None. `check-live-impersonation` sends its requests synchronously inside the Bash tool call (99-126), so
`latest` always moves before the CLI's request; the stand-in (fixed ids, instant answers) cannot exercise overlap.

**Smallest fix (for the owner's decision).** At most one conversation request in flight per run: at admission mark
the current `latest` as being answered and refuse (`conversation-refused`) any further request until that one
settles; release the mark only on a non-2xx/err settle (so the CLI's retry after 429/5xx still works); a 2xx
answer consumes it. The CLI in print mode sends sequentially (all observed requests are), so this should not add
false stops. Also correct §6, §9 and OPERATOR_GUIDE until fixed.

### R2-L1 (LOW) — refusal and stop record are not one critical section

Refusals raised inside `admit_request` (requests-exhausted, output/budget/token limits, ledger-unreadable/unwritable,
conversation-refused) leave the `with self.ledger.lock, self.lock` block by exception; the stop is recorded later by
`refuse() → deny()` (661-662, 549-553) under `self.lock` only. Refusals from `check_request` (outside any lock) and
`redirect-refused` (`settle` at 717, then `refuse` at 718) behave the same. A concurrent request that individually
passes every check can be admitted and sent in that window. The literal claim ("once a stop is recorded…") holds;
the intent ("a terminal refusal ends admission") holds only up to that interleaving. Each such request still passed
its own checks, so no budget or conversation rule is bypassed; this is ordering, not a bypass. Fix: record
`note_stop` inside the critical section before raising (and in `settle` for redirects). Not covered by tests
(all probes are sequential).

### R2-L2 (LOW) — conversation state advances after the client already has the answer

The proxy relays every chunk (742) — including `message_stop` — then waits for upstream EOF, closes, runs
`settle()` (two fsyncs on the bind-mounted ledger) and only then `answered()` (764), outside settle's locks. A
follow-up request checked before `answered()` runs sees the previous state: the CLI's second request is refused
(`not self.opening_answered`, 600) or a later one fails `used ⊆ issued` (602) → `conversation-refused` → the run is
stopped (fail-closed). In practice the window is small: a request arriving during `settle` blocks on
`ledger.lock`, and the handler thread usually takes `self.lock` in `answered()` first; the real exposure is an
upstream that delays the chunked terminator after `message_stop` while the CLI runs a fast tool (Read/Edit). The
stand-in sends `content-length` bodies (`live-standin-agent:137-141`), so EOF is immediate and the race is never
exercised. Related: if the client loses the tail of a 2xx stream the proxy did write, the CLI's retry no longer
answers `latest` and is refused. Fix: call `answered()` inside `settle`'s critical section and, ideally, before
relaying the final event; not a safety issue.

### R2-L3 (LOW) — offline network checked once; upstream host unrestricted

`choose_mode` checks `docker network inspect {{.Internal}}` at start (1266-1268); every run later attaches the proxy
by **name** (`docker network connect "$egress_network"`, 1433) with no re-check. A network removed and recreated
non-internal under the same name between start and a run gives the offline proxy a route out; the upstream regex
(1257) accepts any host, including `api.anthropic.com:443`, and the CA file (1258-1259) is not checked for owner or
mode and is bind-mounted at run time (1422). Requires Docker control (owner-equivalent), and the key sent would be
`offline-credential` (the production `credential` is never mounted in offline mode), so the impact is limited to an
owner who put a real key there. Fix: re-check `Internal` per run (and fail the run), or connect by network ID
recorded at start.

### R2-L4 (LOW) — a recorded stop can be reported as timed-out / output-limit / cancelled

`execute_live_run` picks the outcome in the order cancelled, timed-out, output-limit, egress-failed, then
`provider-stopped` (1512-1527), and adds `provider-stop <stop>` only for `provider-stopped` (1535). A run whose proxy
recorded e.g. `conversation-refused` while the CLI's tool kept running until the wall clock is reported `timed-out`
without the stop reason. Still a failed run (nothing accepted), but the contract's "the helper reports the run
`provider-stopped <that stop>`" fails there and the H2 signal is lost from the result. Fix: emit `provider-stop` whenever
the summary's stop is not `-`, whatever the outcome.

### R2-L5 (LOW) — test coverage of the rule's branches and of real-API conditions

- `forged` (`check-live-boundary:197-203`) runs on a fresh run, so it is refused by `not opening_answered` (600);
  the `used ⊆ issued` branch (602) is exercised by **no** test (removing it would leave every check green).
- "the opening sent again after its answer is refused" (192-193) expects `run-stopped`, i.e. it is masked by the
  earlier `opening-other` stop; the `opening_answered` refusal (594-595) is not tested on its own.
- The stand-in issues fixed ids (`toolu_bash`, `toolu_answer`, …) and `content-length` bodies; no unique ids,
  chunked streams, non-streamed answers, 429/5xx retry of a continuation, parallel tool calls from the model, or
  concurrency are exercised. The real CLI's merged history (request 3 in the investigation carries both tool_use
  blocks in one assistant turn) is handled because all ids remain issued — consistent with the code, verified only
  against the stand-in.

### R2-I1 (INFO) — fail-closed false stops in long runs

`ended` (614-615) is sticky. A `max_tokens` final answer stops the run (stated in §9). Not stated: a client-side
auto-compaction (summary request answered without tool calls → `ended`; then a new history with no assistant turn →
opening refused) also stops the run. Fail-closed; relevant only to long runs; worth one sentence in §9/OPERATOR_GUIDE.

### R2-I2 (INFO) — amendments are exact; one coverage shift

Current digests equal the recorded ones: `check-live-proxy` `ed6f8134…a523f`, `check-live-runner` `cb31fdd4…5cee`;
the frozen R2 files (`check-live-boundary` `24a192c6…3defc`, `live-standin-agent` `c8663db5…f06f4`,
`live-conversation-probe` `6790a1dd…af1ec`, `check-live-impersonation` `1cb2d83c…2c23`) also match. The committed
diffs equal the diffs in `amendments.md`. A-P4.L.R1-1 replaces `200` with `403 run-stopped` and adds "does not reach
the upstream" — stricter. A-P4.L-1 changes no `expect` line (84 remain); it only moves set-up to the offline file and
the credential cases to `offline-credential`. Consequence: credential-unusable/-malformed/-missing on the
**production** path `DIR/provider/credential` are no longer exercised end to end by any live check; the code path is
the same (`$credential_name`, 1400-1403, the proxy's `read_credential`), so the risk is low. (Original digests were
not re-hashed here; the diffs against `f5b86a6` were compared instead.)

### R2-I3 (INFO) — the reported blocking finding is accurate

`check-live-impersonation` 12/13; the one FAIL is the owner's one-request bound, reported as blocking in contract §9,
§10 and the smoke proposal. Accurate. R2-H1 is a separate, stronger gap: not only "more than one request" but
"undetected, with the CLI continuing".

## Checked and holds

- **H1 stop check order.** `admit_request` tests `summary["stop"] != "-"` first (560), under both locks, before any
  limit, budget, conversation check or reservation; refused requests reserve nothing (`check_conversation` at 572 runs
  before `ledger.append` at 576). All 19 codes raised by the proxy are in `STOPPING`; only `run-stopped` is not, and it
  needs none. Stops recorded outside `admit_request` (`auth-refused` 720-722, `usage-unknown` and
  `ledger-unwritable` in `settle` 627/644, refusals via `deny`) keep the first stop (`note_stop` 520-522). Provider
  4xx/5xx other than 401/403 are passed back, charged at reservation, not terminal — as decided. In-flight requests
  settle normally after a stop; one reservation and one settle per admitted request (also in evidence).
- **Helper reports provider stops** as `provider-stopped <stop>` when no other outcome precedes it (1521-1522, 1535),
  and treats admitted≠settled with no stop as `usage-unknown` (1508).
- **H2 one conversation (sequential).** A second opening (different digest or after the answer), a new conversation
  without the run's issued ids, a forged history, a request answering not all of `latest`, and anything after a final
  answer are refused before reservation. Odd roles cannot help an attacker: any role other than `assistant` leaves a
  request an "opening", which is refused once the opening is answered; tool_use/tool_result blocks in any role count
  in `used`. Ids come only from upstream answers that are complete with known usage (streamed: `content_block_start`
  + `message_stop` + usage; non-streamed: parsed `content`); partial or unparsable answers stop the run
  (`usage-unknown`). The opening-retry race (two identical openings in flight) is not reachable by repository code:
  no tool runs before the first answer. Retries after 429/5xx keep `latest` and are admitted. Parallel tool calls are
  answered together by the CLI (investigation, request 3). `--no-session-persistence` in `claude-argv` means no
  transcript with tool ids is on disk; the ids are reachable only via process memory (as stated).
- **H3 modes.** Mode is chosen once (`init_runner` → `init_provider`, called only at 1661). Any of the three
  variables, even set empty (`${VAR+set}`, 1131), turns live runs off before `choose_mode`, before the image check and
  before any key is touched; no key is read or logged in either mode (only paths and the network name are logged).
  Production: `test_upstream`/`test_ca` empty → no `--upstream`/`--ca` (1421-1422) → the proxy's fixed
  `api.anthropic.com:443` with system CAs; egress network `bridge`. Offline: file must be a regular non-symlink,
  owned, mode `*00`, printable ASCII ≤1 KiB, exactly four lines in order; `credential` must be absent (also as a
  dangling symlink); the network must be reported internal; only `offline-credential` is ever mounted
  (`$credential_name`, 1401-1403). An `offline-test` or `credential` created after start changes nothing. No env var
  remains that changes upstream, CA or network; `LOCKSTEP_RUNNER_TEST_LIMITS` only lowers limits. No other script or
  test uses the removed variables.
- **Non-live execution and the frozen `check-runner` path.** The removed top-level `fatal` checks and the `TEST
  OVERRIDE` log line affected only live runs; `execute_run` and `init_runner`'s cleanup are unchanged; the evidence
  for `check-live-runner` (84/84) and `check-live-proxy` (21/21) is clean, `check-live-boundary` 83/83.
