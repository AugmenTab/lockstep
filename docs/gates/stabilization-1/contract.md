# Contract — Post-Phase-5 operational stabilization (S1–S4)

- Contract ID: `C-STAB-1@v1`
- Authority: `.local/plans/phase-05_update4.md` (owner-approved continuation after Gate VM-1, "APPROVED FOR
  IMPLEMENTATION"). Baseline `62f353a` (Phase 5 at `0bd82b2` plus the Gate VM-1 records). Branch `stabilization-1`.
- Writer: the single Implementer. The Implementer does not accept this milestone.
- Scope: exactly the four increments of the handoff, in order S1 → S2 → S3 → S4. Everything in handoff §6 stays out.

## S1 — Native subscription sign-in reliability

| # | Decision |
|---|---|
| S1.1 | **Root cause, established** (`docs/architecture/provider-auth-renewal.md` §1): the pinned CLI renews an expired access token at its OAuth `TOKEN_URL` host `platform.claude.com`; the owner's `egress-hosts` allows only `api.anthropic.com`; the renewal is refused and the CLI sends the expired token (401). The offline `auth status` reports a *stored* token only. Reproduced model-free with the real CLI. |
| S1.2 | **Refusal diagnostics** in the passthrough filter: host, port, reason, run and time of each refused request (`runs/RUN.refusals`, ≤ 64 lines; `refused-hosts` in the summary). Never a header, body, path, query or user information. Allowlist, exact matching and end-to-end TLS unchanged. |
| S1.3 | **Carried to the operator:** `egress.refused` in the signed run result, the helper log names a refused renewal host, the helper names the renewal path at start. |
| S1.4 | **Named failure:** a role whose CLI result is `is_error` with `api_error_status` 401 ends `role-failed provider-auth-rejected` (not `role-crashed`); the page gives the one action. Nothing retried by itself. |
| S1.5 | **Honest preflight:** `capsule-preflight` reports `provider-login-stored` as a local check and `provider-renewal-path` (WARN when blocked). No remote validation (it would be provider traffic, unauthorized here). |
| S1.6 | **Security decision requested, not taken:** S1-SD1, allow `platform.claude.com` in the owner's `egress-hosts` (`provider-auth-renewal.md` §4). The Implementer does not change the owner's configuration. `claude setup-token` not adopted. |

## S2 — Reproduction semantics and effective retries

| # | Decision |
|---|---|
| S2.1 | **A reproduction command may be omitted; a RED baseline may not.** With no command, the Supervisor records the reproduction as not run (`command` null, `reproduced` false — never a success) and continues to the candidate tests (`reproduction-omitted`). The candidate stage's RED rules are unchanged: a test must fail for its signature at the basis (`red-confirmed`), a wrong reason or a GREEN-only candidate is corrected within the budget, then `candidates-exhausted`. |
| S2.2 | **A supplied command is still run and its outcome recorded.** One that does not reproduce still halts `reproduction-missing` (evidence that the Planner's understanding may be wrong). |
| S2.3 | **No ineffective retry.** At `reproduction-missing` the choices are `accept-non-reproduction`, `replan` (the Planner's discovery runs again, which may give a different command) and `stop`. `retry` (the same deterministic command, the same basis) is no longer offered there; a decision request accepts only its own choices. |
| S2.4 | **A retry names what runs again.** Each halt's question and page say which operation a retry executes (`retryOperation`, per stage). Retry still re-enters exactly the halted stage; uncertain effects are still never replayed by themselves. |
| S2.5 | **Halt classes reviewed** (`docs/gates/stabilization-1/retry-model.md`): every other halt's retry re-runs a role (new answer possible), re-checks a condition the operator can fix, or re-runs a command whose environment can change; none is known-impossible. |
| S2.6 | **Frozen tests amended** only where they encode the contradiction (`amendments.md`, A-STAB-1, A-STAB-2), under this handoff's explicit authorization (§3.3: "follow the established amendment/supersession procedure… authorizes the specific semantic correction above"). DG-06 D-6.6 is superseded in part, recorded in the decision register. |

## S3 — Test quality and review depth

| # | Decision |
|---|---|
| S3.1 | **Planner candidate guidance:** learn and follow the project's test conventions (framework, organization, registration, fixtures, naming, nearest existing tests); extend the real suite; no standalone runner; test the behavior (several inputs, boundaries, properties where used, positive and negative, public interfaces); ask whether a special-cased fix would pass. |
| S3.2 | **Reviewer scope:** the context lists every file the change touches (basis to candidate, tests included); the Reviewer must read them all and list what it read (`inspected`). An approval whose declared scope misses a changed file is not an approval: it is recorded as `needs-human` with the gap named, and the transaction halts for a person (retry runs the Reviewer again). |
| S3.3 | **Not changed:** the Supervisor's byte-level freeze enforcement, the Challenger stages; no Verifier role. |

## S4 — Attended-session continuity

| # | Decision |
|---|---|
| S4.1 | The engine never depended on the browser session; an expiry leaves every Work Unit, transaction and open decision exactly as it was (stated and tested). |
| S4.2 | When the app's session ends, the page says that nothing was decided or lost, and remembers the page the operator was on; the next sign-in in that browser returns there (only an address the app itself routes; once). Session lifetime, revocation and CSRF/origin protections unchanged. |

## Verification

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-renewal` (new) | host: real Docker, helper, pinned CLI, TLS stand-in | S1.1–S1.3: V, R, X, N, C (41 checks) |
| `test/unit/Lockstep/Effects/RoleCrashTest.hs` (new) | unit | S1.4 |
| `test/unit/Lockstep/Kernel/ReproductionRetryTest.hs` (new) | unit | S2.1–S2.4 rules |
| `test/integration/Lockstep/StabilizationReproductionTest.hs` (new) | integration: PostgreSQL, Git, processes | S2 cases 1–10 of handoff §3.3 |
| `test/unit/Lockstep/Effects/RoleInstructionsTest.hs` (new) | unit | S3.1, S3.2 instructions |
| `test/integration/Lockstep/StabilizationReviewTest.hs` (new) | integration | S3.2: incomplete review is never an approval |
| `test/integration/Lockstep/StabilizationSessionTest.hs` (new) | integration | S4.1, S4.2 |
| Existing qualification | `scripts/check --integration`, live checks, capsule runner | no regression |
