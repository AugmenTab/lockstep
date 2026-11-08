# Review: the R2-H1 correction (`da7d70a..7018df9`)

Independent and read-only. I ran nothing. Scope: R2-H1 (with R2-L2, now R2-H1c) as corrected in
`scripts/runner/provider/egress-proxy`, plus the frozen regression `scripts/lib/check-live-concurrency`
(and its `live-continuation-probe` and `live-upstream-tools`), the evidence
`.local/evidence/live-concurrency-20261029t204313z/results.txt` (17/17) and the baseline
`.local/p4lr2-concurrency-baseline.log` (C2 and C3 fail, 6 failures). Line numbers refer to `7018df9`.

**Verdict: R2-H1: CLOSED.** HIGH 0, MEDIUM 0, LOW 2, INFO 4.

## 1. Can two requests of one conversation both be admitted or both reach the upstream?

No, not at the same time, and two complete answers can never answer the same `latest`.

- `in_flight` is tested (`check_conversation` 598) and set (`admit_request` 582) inside one critical section,
  under `ledger.lock` then `self.lock` (560). Test-and-set is atomic, so the second of two concurrent requests
  is refused `conversation-refused`. That code is in `STOPPING` (109), so the run stops and later requests get
  `run-stopped`.
- The same check covers all three shapes: two continuations, two openings (the in-flight test comes before the
  opening checks at 600-605), and an opening with a continuation. A continuation also needs `opening_answered`,
  and that is set only in `settle` while `in_flight` is cleared under the same locks (629-631).
- `in_flight` is cleared in exactly one place, `settle` (631). Every path that reaches `settle`:
  - a redirect (731), with no conversation, so the state does not move;
  - an error status, read fully (781), so the state does not move;
  - a complete 2xx answer (781), where the state moves first;
  - a broken stream or client disconnect (`except` at 777, then 781). With status 200 this is
    `usage-unknown`, which stops the run.
- `settle` clears `in_flight` only after the upstream body has been read to EOF, or after an exception.
  - It is cleared "early" (upstream still generating) only on the exception path.
  - On a 2xx that path always stops the run (`usage-unknown`).
  - On a non-2xx there is nothing left to generate.
- Sequential re-admission (same `latest`, after an answer that was not complete) is R2-H1b as designed. It
  cannot yield two complete answers to one `latest`, because a complete answer moves `latest` in the same
  critical section that clears `in_flight`.
- `in_flight` can stay set forever only if an exception escapes `do_POST`. See LOW-1: the run then fails
  closed.

## 2. R2-H1c: does the state move before delivery?

Yes, on every path that delivers a complete answer.

- `move_conversation` runs inside `settle`, under both locks, just before `in_flight = False` (629-631).
- The last chunk is held back (722, 759-762) and written only after `settle` (783-788).
- The socket closes only when `do_POST` returns (`close_connection`, 745), so the client sees EOF after the
  state has moved even if it ignores the held chunk.
- On the exception path the held chunk is dropped (779). That path never moves the state.
- The CLI's immediate next request after a complete 2xx answer therefore cannot be refused for arriving early.
  C1 (ten back-to-back continuations) passes.

One residual window remains for non-2xx answers. See LOW-2.

## 3. Legitimate retries and the multi-turn flow

- **Retry after 429/5xx:** `in_flight` is cleared and the state is unchanged (H2 condition at 629), so a retry
  is admitted. This is covered for the opening only (C6). The window is in LOW-2.
- **Broken 2xx stream:** already terminal before this change (`usage-unknown`). No new effect.
- **Client abort while the upstream stalls:** this covers the CLI's stream-idle fallback to a non-streaming
  request. The proxy notices the abort only on its next write, so the fallback is now refused while the old
  request is still in flight. The outcome is unchanged, though: the aborted 2xx later settled
  `usage-unknown` and stopped the run anyway (INFO-2).
- **Parallel tool calls:** `tool_ids` collects every `tool_use` block (stream 478; non-streamed 773-774).
  `latest` becomes all of them, and the next request must answer all of them (`latest <= answered`, 611).
  Unchanged.
- **Merged history:** the `used <= issued` check (609) is unchanged.

## 4. Does the regression test what it claims?

- **C2 and C3:** the stand-in upstream sleeps 2 s (`--delay 2`), while the probe's two threads start within
  milliseconds (`live-continuation-probe` 56-70). The second request therefore always arrives while the first
  is in flight, so the result is deterministic in practice. Without the fix both are admitted (200 200, and
  2 or 3 upstream requests). The baseline shows exactly these six failures, so the test does fail when the fix
  is removed.
- **C1:** it does not tell R2-H1c apart from the old code (INFO-1).
- **Not covered:**
  - a continuation retried after a 5xx (only the opening, C6);
  - a broken or aborted stream;
  - a request arriving between the response headers and `settle` (LOW-2).

## 5. Anything new the correction introduced

- **Lock order:** `admit_request` and `settle` both take `ledger.lock` and then `self.lock`. `deny` and the
  `do_POST` updates (692, 709, 735) take only `self.lock`. `write_summary` calls `Ledger.totals`, which does
  not take `ledger.lock` (190-221). No inversion and no new acquisition, so no deadlock.
- **Accounting:** unchanged. There is still one reserve and one settle per admitted request, and the redirect
  path still settles once (731).

## Findings

### LOW-1: `in_flight` stays set for good if an unexpected exception escapes (it fails closed)

`egress-proxy:582-585`, `449`, `770-776`, `777`.

`in_flight` is set before `write_summary()` (585). If that raises `OSError`, for example because the runs
directory is unwritable, the error is not a `Refusal`, so it escapes `do_POST` (706 catches only `Refusal`)
and nothing settles the request.

The same happens for any exception outside `(OSError, HTTPException, SSLError)` between admission and
`settle`. For example, a `RecursionError` from deeply nested JSON in an upstream event (449, or 770, where
only `ValueError` is caught).

After that, every request in the run is refused `conversation-refused` and the run stops; the reservation
stays charged, as before.

This fails closed and is not a safety issue. Before this change the same leak left the run able to continue,
so the new consequence is a false stop rather than a bypass. The upstream is a fixed, TLS-verified host, so
this is unlikely.

Fix idea: settle in a `try/finally` that is set up right after `admit_request` returns.

### LOW-2: a non-2xx retry can race `settle` and cause a false stop

`egress-proxy:738-744` (headers sent), then `752-781` (body read, then `settle` with two fsyncs).

For an error status the client gets the status line before the proxy has read the upstream body and settled.
An SDK that retries on 429/5xx can cancel the body without reading it and resend after its backoff (hundreds
of milliseconds, or `retry-after`). If the body read plus the ledger and summary fsyncs take longer than that
backoff, the retry finds `in_flight` set and is refused `conversation-refused`, which stops the run. The same
applies to the opening.

This normally takes milliseconds, so it is a remote false stop, and it fails closed. The contract's "the CLI's
immediate next request is never refused" holds for complete answers, but not strictly for error answers.

Fix idea: for a non-2xx status, read the (bounded) body and settle before calling `send_response`.

### INFO-1: C1 does not exercise R2-H1c; contract §11 overstates this ("R2-L2 Fixed … covered by C1")

`check-live-concurrency:118-127`. C1 passed on the pre-fix baseline (baseline line 2). The probe reads to EOF
(`live-continuation-probe` 29), and EOF comes only after `do_POST` returns, which in both versions is after
the state moves. So C1 is a no-regression guard and not a regression test for the held chunk. The code itself
is correct (section 2).

### INFO-2: an aborted or fallback request now fails at once instead of later

A client abort during an upstream stall shows up only on the proxy's next write, so a CLI fallback request
sent in between is refused. Before the fix it was admitted, but the run then stopped on the abandoned
request's `usage-unknown`. The outcome is the same (the run stops), only earlier.

### INFO-3: R2-H1b releases the tool calls after any non-2xx, by design

A request that answers `latest` and gets an error answer (for example a deliberately invalid body that the
upstream rejects with 400, which is not terminal) frees `latest` for the next request. No complete answer is
issued twice. The sequential one-request bound (impersonation 12/13, reported as blocking) is a separate, open
item and outside this review.

### INFO-4: the evidence matches the code

17/17 after the fix. The baseline fails exactly C2 and C3 (6 checks). The tests drive the proxy image itself
(`/opt/lockstep/egress-proxy` in `lockstep-provider:claude-2.1.312`). I did not verify here that this image was
rebuilt from `7018df9`; the evidence timestamp (20:43Z) comes after the fix.
