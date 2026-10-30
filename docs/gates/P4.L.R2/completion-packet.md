# Completion packet — final live-provider hardening (C-P4.L.R2)

- For: the owner. Prepared 2026-10-29/30 by the writing agent (Implementer, manual) under
  `.local/plans/phase-04_update4.md` (sha256 `bdf52c60…cfd7e1f`). The Implementer cannot accept Gate C-EXEC or mark
  anything Done.
- **Readiness verdict: NOT READY for the real-provider smoke without one owner decision** (§7): the owner's H2
  condition "at most one impersonated request" does not hold, and per the owner's instruction that is reported as a
  blocking finding.

## 1. HEAD, tree, diff

- Candidate: **`7018df9`** (code); HEAD `b3c373a` + this packet (documents only). Working tree clean at every
  qualification.
- Remediation diff `f5b86a6..b3c373a`: 17 files, +2175 −47 — production: `scripts/runner/provider/egress-proxy`
  (+143), `scripts/control-helper` (+94); the rest checks, test tools and documents. Commits: `6e47b75` (freeze),
  `f7c0810` (approved amendments), `307897e` (adversarial regression), `da7d70a` (H1–H3), `38bcf53` + `5e345c1`
  (review regression, contract), `7018df9` (review fix), `b3c373a` (review record).

## 2. H1, H2, H3

| # | Disposition | Code |
|---|---|---|
| H1 terminal refusal | **Closed.** Every proxy refusal and every proxy-recorded stop is terminal; after it, every request is refused (`run-stopped` or its own check) and nothing more is reserved or sent; the first stop is kept; in-flight requests settle; a run name is served once. Provider error answers (429, 5xx) are not terminal (retryable, charged at reservation). | `egress-proxy` `admit_request` (stop checked first, under the ledger and run locks); `STOPPING` |
| H2 one writing agent | **Mechanically enforced for any second conversation; one limitation remains (§7).** The proxy, the only route to a model, admits one conversation a run: one opening (retry only unchanged and before an answer), then only requests answering the latest answer's tool calls, issued by the upstream in this run; one request in flight; each answer's tool calls answered once; an ended conversation admits nothing. A second CLI (by name or absolute path), a background session or a direct client is refused and ends the run; demonstrated with the real CLI. Ordinary subprocesses work. | `egress-proxy` `conversation_of`, `check_conversation`, `move_conversation`, `settle` |
| H3 test overrides | **Closed.** Two explicit modes decided at helper start: production (fixed upstream and CAs, bridge, `credential`) and offline test (owner-made `offline-test` file, a Docker network that is internal, `offline-credential`); refused before any key is read: any `LOCKSTEP_RUNNER_TEST_*` variable, offline mode with `credential` present, offline mode on a network that can reach out, a malformed offline file. Not based on key names. | `control-helper` `choose_mode`, `init_provider`, `execute_live_run` |

## 3. Frozen-test amendments

A-P4.L.R1-1 (`check-live-proxy`) and A-P4.L-1 (`check-live-runner`): **APPROVED by the owner** (2026-10-29) and
applied; digests verified equal to the record (`docs/gates/P4.L.R2/amendments.md`). No other frozen test changed: every
frozen check's current digest equals its record.

## 4. RED/GREEN and digests

| Check | Frozen | sha256 | Baseline (RED) | Final (GREEN) |
|---|---|---|---|---|
| `check-live-boundary` | `6e47b75` | `24a192c6…5a1defc` | 39 failures vs `d13ac33` | 83/83 |
| `check-live-impersonation` | `307897e` | `1cb2d83c…cee52c23` | 6 failures | **12/13** (the one-request bound) |
| `check-live-concurrency` | `38bcf53` | `ac19ff3d…cb48b666` | 6 failures (exactly the concurrent cases) | 17/17 |
| `check-live-proxy` (A-P4.L.R1-1) | `f7c0810` | `ed6f8134…b27a523f` | RED vs `d13ac33` on the amended lines | 21/21 |
| `check-live-runner` (A-P4.L-1) | `f7c0810` | `cb31fdd4…20ef5cee` | RED vs `d13ac33` (no offline mode) | 84/84 |

Full digests and evidence paths: `docs/gates/P4.L.R2/contract.md` §4, §9–§11.

## 5. Qualification

- Mac `scripts/check --integration` at `7018df9`: all six steps PASSED — unit **870/870**, integration **571/571**,
  backup/restore, no-live-model guard (sentinel log empty after the integration step).
- Linux clean clone at `b3c373a` (code identical to `7018df9`): format, lint, build, unit and integration PASSED —
  unit **870/870**, integration **571/571**, case-sensitive disks (`.local/p4lr2-linux.log`).
- Host, real Docker: `check-runner` 0 failures, `check-runner-paths` 7/7, `lockstep-stress` PASS, and the five live
  checks of §4 (all against local stand-ins on internal networks).
- Existing recovery and resource-bound tests: in the Mac and Linux runs (C-P4.R1–R3 groups) and the stress test.

## 6. Independent reviews

1. `docs/reviews/phase-4-live-hardening-review-2026-10-29.md` (`f5b86a6..da7d70a`): **1 HIGH**, 0 MEDIUM, 5 LOW,
   3 INFO. The HIGH (R2-H1: two concurrent requests answering the same tool calls both admitted — a second
   conversation turn alongside the CLI's) confirmed, regressed and fixed (`7018df9`).
2. `docs/reviews/phase-4-live-hardening-fix-review-2026-10-29.md` (`da7d70a..7018df9`): **R2-H1 CLOSED**; 0 HIGH,
   0 MEDIUM, 2 LOW, 4 INFO. Both LOW fail closed (a false stop, never a bypass) and are recorded.
   All dispositions: contract §11.

## 7. The remaining agent-multiplicity risk, stated plainly

- **What is enforced:** no second, independent conversation with any model can run during a live run; any attempt
  ends the run (one opening, one request in flight, answers only to tool calls the upstream issued, each once).
- **What is not:** a process inside the role's container can read the CLI's own memory (same user; the Docker VM's
  `ptrace_scope` is 0; `/proc/1/mem` was read in the investigation). Such a process can **continue the run's own
  conversation in the CLI's place** while the CLI waits in a tool call — and not only once: for as many requests as
  the run's own allowances permit (requests, output, budget, wall clock). When the CLI's own next request arrives it
  is refused, the run stops `conversation-refused`, and nothing it produced is accepted (no answer, no review, no
  Supervisor commit; the fix halts for a person; the workspace stays untrusted). Shown by `check-live-impersonation`:
  everything the owner conditioned holds except the one-request bound.
- **The owner's conditions** (H2 decision): 1 fail-closed — **holds**; 1 at most one impersonated request — **does
  not hold** (blocking, as instructed); 2 the same budget, allowance and reservations — holds; 3 no accepted result
  from a stopped run — holds; 4 documented — here and in the contract §6/§9; 5 the hardening item — recorded (§8);
  6 attended, disposable repository only — written into the smoke proposal.
- **Smallest correction (not built):** run the CLI and the processes its tools start as different users inside the
  container, so no tool process can read the CLI's memory; then re-run `check-live-impersonation` expecting the
  impersonator to fail to read and the bound to be zero. It changes the provider image and the helper's run command;
  not the Supervisor, the engine or the number of Implementers. The owner's item 5 asks also to evaluate ptrace
  restrictions, `process_vm_readv` and `/proc/<pid>/mem` without assuming one control closes every path.

## 8. Recorded for later (the owner's hardening item 5)

Process-memory isolation between the provider CLI and the processes running repository code: privilege separation,
ptrace restrictions (`kernel.yama.ptrace_scope`, seccomp), `process_vm_readv`, `/proc/<pid>/mem`; verified by an
adversarial check, not assumed from one setting.

## 9. Confirmations

- Installation: **none** (the operator's installation, service, helper and launcher unchanged).
- Real credentials: **none** created, requested or loaded (synthetic `sk-ant-test-…` keys only, removed by the checks).
- Live provider calls: **none** (every upstream a local stand-in on an internal network; the guard's sentinel log empty).
- Production engine enabled: **no**. Real coding transaction: **none**. Git remotes: **unchanged** (nothing pushed).
- Frozen contracts and tests: digests as recorded, except the two approved amendments.

## 10. Recommendation and the decision needed

**H1 and H3 are closed; H2 is enforced against any second conversation, with one exactly described limitation that
fails the owner's one-request condition.** Two ways forward, the owner's choice:

1. **Accept the measured bound for this one attended, disposable smoke** (an impersonator bounded by the run's own
   allowances, then the run stops with nothing accepted), recording it as an exception; then the revised smoke
   proposal (`docs/gates/P4.L/real-provider-smoke-proposal.md`) is ready for the owner's approval steps.
2. **Require the process-isolation correction (§7) first**, under a new narrow contract, before the smoke.

Gate C-EXEC is not claimed; Phase 5 and the dogfood project are not started.
