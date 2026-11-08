# Budget enforcement report (C-P4.L L5) — what is enforceable, and what is not

- For: the owner, before any live run. Prepared 2026-10-29 by the writing agent (Implementer, manual).
- Answers `.local/plans/phase-04_update3.md` §7: "establish whether the selected provider and adapter can actually
  enforce a maximum charge … do not describe a post-hoc usage check as a hard spending cap."
- Evidence: `scripts/lib/check-live-runner` (cases 4, 9, 12–14, 20, 21), offline against a stand-in upstream; no
  provider was contacted.

## 1. What the Claude Code CLI itself offers, and why it is not the cap

The pinned CLI (2.1.312) has `--max-budget-usd` and reports `total_cost_usd` and `usage` at the end
(`--output-format json`). Both are the CLI's own estimates from its own price table, computed **inside the role's
container** after each response arrives: a check after the fact, by the process Lockstep confines. Lockstep does not
pass `--max-budget-usd` and does not rely on the CLI's figures; its JSON is kept as the run's evidence only.

## 2. What Lockstep enforces, and how

All of it in the egress proxy, outside the role's container, on the only path to the provider (L2). Its ledger is
the helper's (`DIR/provider/ledger/ledger`), append-only and synced before a request is sent, for the whole budget
across runs, helper restarts and the person's retries.

| Limit | Enforced | How |
|---|---|---|
| **Total spend** (`budget-micro-usd`) | **Yes, before each request** | *spent* = every settled charge + every reservation not yet settled. A request is sent only if *spent* + its reservation ≤ the budget. Its **reservation** is the largest charge it can cause: every prompt byte counted as a token (+ 4096 for what the provider adds) at the dearest input price (1-hour cache write), plus `max_tokens` at the output price, at long-context prices when the prompt could be long. After the response the reservation is replaced by the charge from the provider's reported usage. A response whose usage cannot be read keeps its full reservation and stops the run (`usage-unknown`); so does a request the proxy never finished (proxy stopped or killed: case 20). |
| **Total tokens** (`token-limit`) | **Yes, before each request** | The same, counting all tokens: uncached input, both cache writes, cache reads and output. |
| **Output tokens per request** (`request-max-tokens`) | **Yes** | A request asking more is refused (`max-tokens-refused`); the helper sets `CLAUDE_CODE_MAX_OUTPUT_TOKENS` to it, so the CLI asks for exactly that. The provider never writes more than `max_tokens` (thinking included). |
| **Output tokens per run** (`invocation-output-tokens`) | **Yes** | settled output + open reservations' `max_tokens` + this request's ≤ the allowance (`output-allowance-exhausted`). |
| **Requests per run** (`invocation-requests`) | **Yes** | The next request is refused (`requests-exhausted`; case 12: exactly 3 of 3 sent). |
| **Live runs in total** (`invocation-limit`) | **Yes, before a run** | Counted in the ledger; past it nothing starts (`invocation-limit-reached`). The engine's own bounds (DG-06, DG-17) apply too. |
| **One model, one effort** | **Yes** | Any other model or effort is refused per request (`model-refused`, `effort-refused`); no fallback model is passed. |
| **Wall clock per run** | **Yes** | The helper's: Implementer 20 min, others 10 min (C-P4.2, unchanged). |
| **Wall clock for the whole smoke** | **No** | Nothing in Lockstep counts time across runs. The owner stops it (*Stop* on the halt, `lockstep stop`); the worst case is bounded by runs × per-run limits. |

Why the total is a hard cap: before each request, *spent* + reservation ≤ budget; each request's real charge is at
most its reservation (below); and a reservation is released only when replaced by a smaller or equal real charge.
Requests of one run may be in flight together: each is admitted under the ledger's lock with its reservation held,
so together they still fit.

## 3. The assumptions the cap rests on (stated, not hidden)

1. **A prompt has no more tokens than its bytes, plus 4096.** True for text (a token is at least one byte; JSON
   only adds bytes). Images and documents, where it may not hold, are refused (`content-refused`).
2. **The provider charges no more than its prices in the owner's pricing basis for the usage it reports.** The owner
   names and confirms the basis (`pricing`); higher prices than the real ones only make the cap stricter.
3. **The provider bills nothing the usage report does not show.** Server tools (web search, code execution), which
   bill separately, are refused; a usage report showing any is treated as unknown (charged at the reservation).
4. **A refused or failed response** (4xx, 5xx, a broken connection) is charged at its full reservation, though the
   provider normally bills nothing for it: retries on overload use up the budget early rather than ever overspend.

If assumption 1 or 2 were broken, the overshoot would be bounded by one request's difference: its real charge is
written to the ledger as it is, and nothing further is admitted.

## 4. What it costs in practice (measured offline)

With `--bare` the CLI's request body is about 4.4 KB (ledger of case 4: reservations of 24 462 and 24 926 tokens,
of which 16 000 are `max_tokens`). At the conservative rates of the smoke proposal (input 3, 1-hour write 6, output
15 USD per million) one request reserves about **0.29 USD**, nearly all of it for its possible output. Each request
releases its reservation when settled, so the reservation matters only near the end: with a 5 USD budget the last
~0.29 USD (more if requests overlap) cannot be used. Real spend therefore stays at or under the budget.

## 5. Reconciling the proposed ceilings (handoff §7) with this behaviour

| Proposed | Verdict | Recommendation for the smoke |
|---|---|---|
| 5 USD total | Enforceable as a hard cap (§2) | **5 000 000 micro-USD** |
| 400 000 tokens total | Enforceable, but counts cache reads: Claude Code re-reads its prompt on every turn (tens of thousands of cached tokens a turn), so 400 000 all-inclusive tokens would stop a normal Implementer run early | **3 000 000 tokens all-inclusive**, the dollar cap binding; or keep 400 000 and accept an early stop — the owner's choice |
| 60 000 output tokens a run | Enforceable | **60 000**, with **16 000** a request |
| 13 role runs | Enforceable | **13** |
| ~6 on the happy path | The engine's path (discovery, candidate, challenge, implement, challenge, review) | — |
| 60 minutes in total | **Not enforced** (§2) | The owner watches and stops; per run 20/10 min are enforced |
| Implementer 20 min, others 10 min | Enforced (helper) | unchanged |

A further per-run limit not in the proposal: **80 requests a run** (a turn of the CLI is one request).
