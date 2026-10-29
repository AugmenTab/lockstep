# Proposal — the first real-provider smoke, revised (for the owner's authorization)

- Status: **PROPOSED — NOT RUN.** Supersedes `docs/gates/P4.17/real-provider-smoke-proposal.md`. Nothing below has
  been done: no provider was called, no real credential exists, nothing is installed, the operator's helper does not
  run with `--runner`, and no real coding transaction has run. **Each numbered approval in §2 is the owner's.**
- Prepared 2026-10-29 by the writing agent (Implementer, manual) under `.local/plans/phase-04_update3.md` §11.
- Built on: C-P4.L (adapter, egress, credentials, budget; `docs/gates/P4.L/contract.md`), the budget report
  (`docs/gates/P4.L/budget-report.md`), C-P4.R3 (one engine owns a step).
- It would show: one real model, through the real installed service, worker, helper, container, proxy and Git
  boundary, fixing one small real bug with real tests, a real challenge and review, the Supervisor's local commit,
  and a person deciding. It would not show: coding ability in general, cost at scale, or anything about the later
  dogfood project (which this is not; that project's PRD is the owner's, separately).

## 1. The smoke

| Item | Proposal |
|---|---|
| Repository | A **new, disposable** project made in the browser, in a new folder under `~/lockstep-projects` ("calc smoke"): `calc.py` with `def add(a, b): return a - b` and nothing else, committed by the owner. No remote, not an existing repository. |
| Bug | Task "add subtracts instead of adding"; done looks like: "add(2, 2) is 4 and add(1, 2) is 3". |
| Provider and model | Claude Code CLI **2.1.312** (pinned in `lockstep-provider:claude-2.1.312`), model **`claude-sonnet-5-5`**, effort **`medium`**, every role. The model and effort are the owner's choice (offered: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-fable-5-1`; `low`…`max`); one model and one effort for the whole smoke; no fallback. |
| Hard limits (enforced, §3) | Budget **5.00 USD**; **3 000 000** tokens all-inclusive (or 400 000 if the owner prefers an early stop; budget report §5); **16 000** output tokens a request; **60 000** a run; **80** requests a run; **13** live role runs; Implementer 20 min, other roles 10 min. |
| Not enforced | The 60-minute total: the owner watches and stops (§5). |
| Network | The role's container: only its own internal network and the proxy; the proxy: only `api.anthropic.com:443`. Verification and scripted runs: no network. |

## 2. Exactly what needs the owner's authorization, in order

1. **Gate C-EXEC** (its packet, `docs/gates/C-EXEC/decision-packet.md`), or an explicit decision to run the smoke
   before it.
2. **The pricing basis.** Confirm the model's prices on Anthropic's own pricing page on the day, and write them in
   the configuration (§3). The values below are conservative placeholders (the highest found in third-party sources;
   no official page was consulted): **input 3, output 15, 5-minute cache write 3.75, 1-hour cache write 6, cache read
   0.30 USD per million tokens**. Higher than the real prices only makes the cap stricter.
3. **Install the candidate** on this Mac (the control pane's *Install*, or `scripts/service install` then apply), and
   build the provider image: `scripts/provider-image` (downloads the CLI package from the npm registry, checks its
   SHA-512; contacts no model provider).
4. **Create the credential**: a new API key in a **dedicated Anthropic Console workspace** for this smoke, with the
   Console's own workspace spend limit set to 5 USD if the Console offers one (a second cap, on the provider's side).
   The owner writes it, never pasting it into a conversation:
   `.local/control/provider/credential` (directory 0700, file 0600, the key on one line).
5. **Write the configuration** `.local/control/provider/config` (0600):

   ```
   lockstep-provider 1
   provider claude-code
   model claude-sonnet-5-5
   effort medium
   pricing anthropic-<date-confirmed>
   price-input 3000000
   price-output 15000000
   price-cache-write-5m 3750000
   price-cache-write-1h 6000000
   price-cache-read 300000
   long-context-tokens 200000
   long-context-input-percent 200
   long-context-output-percent 150
   budget-micro-usd 5000000
   token-limit 3000000
   invocation-limit 13
   request-max-tokens 16000
   invocation-output-tokens 60000
   invocation-requests 80
   ```

6. **Start the helper with `--runner`.** The launcher does not do this yet. Either (a) by hand, after `./lockstep stop`:
   `scripts/control-helper --state <checkout>/.local/control --service-port 8000 --projects ~/lockstep-projects
   --runner`, then restart the service from the control pane (so it gets the runner channel); or (b) authorize a small
   launcher change that adds `--runner` when `.local/control/provider/config` exists (built and tested before use).
   Check: the helper's log says `live runs on: claude-code claude-sonnet-5-5 medium, at most 16000 output tokens a
   request`; the service's log says `Engine worker: on (live provider claude-code, model claude-sonnet-5-5, effort
   medium)`.
7. **Run one smoke** as in §4, with the limits of §1 and the stop conditions of §5. No second smoke without a new
   authorization.

## 3. Why the limits hold (summary of the budget report)

Every request goes through the proxy, which reserves its largest possible charge in the ledger
(`.local/control/provider/ledger/ledger`) before sending it, and refuses it if the reservation does not fit what is
left; the reservation is replaced by the real charge from the provider's usage report; unreadable usage keeps the
full reservation and stops the run. The ledger survives restarts and retries; nothing the service sends resets it.
At these prices one request reserves about 0.29 USD; real spend stays at or under 5 USD. The assumptions (text
only, the pricing basis not lower than the real prices, no billing outside the usage report) are in the report §3.

## 4. The workflow, and the evidence to keep

1. In the browser: the new project, **Let Lockstep fix bugs here**, the task, **Mark as ready**, **Ask Lockstep to fix
   this bug**.
2. The task page's *Fixing it*: finding the cause (Planner), the Contract and failing tests (Planner), their check
   (challenger), the freeze, the change (Implementer, the only writer, in its own container), the checks run by
   Lockstep, the challenge after it, the review (Reviewer), the Supervisor's local commit on `lockstep/<work order>`
   (never `main`, never pushed). About 6 role runs if nothing goes wrong.
3. **Is this bug fixed?** — the owner decides Done or not. Lockstep never decides it.

Evidence checklist (the owner's observations are the owner's own words, never generated from automation):

- [ ] The helper's and the service's start lines (§2.6).
- [ ] Every invocation: role, argv (model, effort, session id = the helper run), outcome, exit, digests, the kept
  answer — from the database, as the task page's technical details show them.
- [ ] Every live run's signed result with its `egress.*` fields, and the ledger (`reserve`/`settle` lines): total
  charge, tokens, unknown usage (expected none).
- [ ] The proxy's refusals (expected none) and the paths it saw (only `/v1/messages?beta=true`).
- [ ] The helper's runner journal: every run started and ended; no `interrupted`.
- [ ] `docker ps -a` and `docker network ls` after the smoke: no `lockstep-run-`, `lockstep-egress-` or
  `lockstep-live-` left.
- [ ] The Git branch: its commits by the Supervisor only; the frozen tests unchanged; the fix within the allowed path.
- [ ] The Anthropic Console's usage for the workspace, compared with the ledger.
- [ ] The owner's written observations and decision.

## 5. Stop conditions (any one: *Stop* on the halt, no *Try again*)

A halt of any kind; an uncertain invocation; any `provider-stopped` (budget, tokens, limits, a refused request,
unknown usage, egress failure, a refused credential); any change outside the allowed path or to a protected test
(refused by the Supervisor anyway); a `CONFIRMED` finding after the second attempt; 60 minutes from the start; the
owner's word. To stop at once: *Stop* on the page, then `./lockstep stop` (the helper removes the run, its proxy and
its network; a request in flight stays charged).

## 6. Clean-up and reset

*Done* or *Stop* on the page. Revoke the key in the Anthropic Console, then delete `.local/control/provider/credential`.
Keep the ledger and the run summaries (`.local/control/provider/ledger/`) and the database records as evidence (or
restore the backup taken before installing). Start the helper again without `--runner` (or `./lockstep`), so no live
run can start. Delete the throwaway project's folder when the evidence is kept. A later trial starts from a new
authorization; it may reuse the ledger (the budget continues) or the owner may archive it to begin a new budget.
