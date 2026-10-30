# Gate C-EXEC — decision packet (revised after the live-provider increment)

> **Superseding note (2026-10-30, `phase-04_update4.md`):** the candidate is now **`7018df9`** (the final hardening,
> C-P4.L.R2: terminal refusals, one conversation a run, explicit offline-test mode). Its completion packet is
> `docs/gates/P4.L.R2/completion-packet.md`, which supersedes §1–§3 below for the live path. It reports one blocking
> finding for the real-provider smoke (the owner's one-request bound on an impersonating process does not hold) and
> the decision the owner needs. Everything below is otherwise unchanged.

- For: the owner. Prepared 2026-10-29 by the writing agent (Implementer, manual). The Implementer cannot accept Gate
  C-EXEC or mark anything Done; this packet recommends.
- Branch `phase-4` (from `77a96ce`). Authority: `.local/plans/phase-04.md` (`24db39d9…`), `…_update1.md`
  (`4cb620d3…`), `…_update2.md` (`c3b2a6fd…`), `…_update3.md` (`97c86589…`).
- **Qualified candidate: `d13ac33`** (working tree clean). Mac `scripts/check --integration`: all six steps PASSED —
  unit 870/870, integration 571/571, backup/restore, no-live-model guard (sentinel log empty after the integration
  step; construction gate: `Provider.Live` imported by `Main` only). Linux clean clone: unit 870/870, integration
  571/571 (case-sensitive disks). Host, real Docker: `check-runner` 0 failures, `check-runner-paths` 7/7,
  `check-live-runner` **84/84**, `check-live-proxy` **20/20** (both against a local stand-in upstream; no provider);
  `lockstep-stress` PASS. Logs: `.local/p4l-check-mac.log`, `.local/p4l-linux.log`,
  `.local/evidence/runner-20261029t180011z/`, `.local/evidence/runner-paths-20261029t180047z/`,
  `.local/evidence/live-20261029t171956z/`, `.local/evidence/live-proxy-20261029t171931z/`.
- Supersedes the packet at `aba8b33` (candidate `54966a4`), whose content §1–§3 below keeps.

## 0. The five questions the handoff asks to answer plainly (update3 §12)

| Question | Answer |
|---|---|
| Has installation occurred? | **NO.** Nothing was installed or upgraded; the operator's installation, service and helper are untouched. |
| Do real credentials exist? | **NO.** Only synthetic keys (`sk-ant-test-…`, made and removed by the checks); no real key was created, asked for or loaded. |
| Did any live provider call occur? | **NO.** Every live-path check used a local stand-in upstream on an internal network with no route out; the no-live-model guard's sentinel log is empty. One remark, for completeness: building the provider image downloads the Claude Code CLI package from the npm registry (not a model provider, no credential). |
| Has the production engine been enabled? | **NO.** The operator's helper runs without `--runner`; no `provider` directory exists in the operator's state. |
| Has any real coding transaction run? | **NO.** Only scripted roles and stand-ins. |

## 1. What this increment did

| Item | What | Frozen → implemented | Evidence |
|---|---|---|---|
| Workstream A | The final independent read-only review of P4.R2 (`b77bc81..54966a4`): no HIGH, **one MEDIUM** (two engines on one database falsely halting each other's live runs), three LOW, six INFO (`docs/reviews/phase-4-r2-final-review-2026-10-29.md`) | — | — |
| **P4.R3** | The MEDIUM corrected: a stage belongs to the engine running it (the transaction's session lock for the whole step; another engine is told `busy`); recovery after an engine has gone unchanged | `70ef870` → `b0b922d` | every C-P4 group 142/142 |
| **P4.L** (B1–B3, §7) | The live Claude Code adapter; restricted egress through a per-run proxy; the key held by the proxy alone; a ledger-backed budget reserved before every request | `a6b69e2` → `c7a6d54` | unit 8/8, engine 7/7, host `check-live-runner` 84/84 |
| Review | Independent read-only review of the new integration (`b0b922d..c7a6d54`): no HIGH, **two MEDIUM** (duplicate JSON keys checked one way and forwarded another; top-level fields denylisted, so a price-changing field could pass), eight LOW, eight INFO (`docs/reviews/phase-4-live-integration-review-2026-10-29.md`) | — | — |
| **P4.L.R1** | Both MEDIUMs and five LOWs corrected (the checked document is what is sent; only the CLI's fields; a run name once; every refusal a stop; final usage counted; watchdog by deadline; test overrides logged); the rest dispositioned | `8d0790c` → `d13ac33` | `check-live-proxy` 20/20; `check-live-runner` 84/84 |

Deliverables: the reviews above; `docs/gates/P4.L/contract.md` (the adapter, egress, credentials, budget, with the
freeze record and digests); `docs/gates/P4.L/budget-report.md` (what is enforceable and what is not);
`docs/gates/P4.L/real-provider-smoke-proposal.md` (revised: owner approvals in order, configuration, caps, workflow,
evidence checklist, stop and reset); `docs/gates/P4.R3/contract.md`; `docs/gates/P4.L.R1/contract.md`.

## 2. The provider integration in one page

- **Adapter.** Claude Code CLI **2.1.312** pinned by SHA-512 in `lockstep-provider:claude-2.1.312`; `claude -p --bare`
  with one configured model and effort (offered: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`,
  `claude-fable-5-1`; `low`…`max`), tools `Read Edit Bash`, no session kept, no MCP, no fallback model; anything else
  refused, never replaced. Verified offline: the CLI's real flags, endpoint (`POST /v1/messages?beta=true` only),
  headers, beta features and tool names, against a stand-in. The answer only through `result.json` (C-P4.5).
- **Egress.** Each live role run: its own `--internal` network; the role's container (read-only root, no
  capabilities, the C-P4.2 mounts and limits) reaches only the run's proxy; the proxy reaches only
  `api.anthropic.com:443` (TLS verified), answers only the Messages API, sends its own serialization of a checked
  request (one model, one effort, the CLI's fields, the role's tools, text only, the six observed beta features), never
  follows a redirect, and stops the run on any refusal. Checks and scripted roles keep `--network none`.
- **Credential.** `.local/control/provider/credential` (0600), read by the proxy of one run only, never by the role's
  container, the service or anything kept; refused if missing, readable by others or malformed.
- **Budget.** Hard caps on spend, tokens, output and requests (budget report §2), by reservation before each request
  in a durable ledger; the 60-minute total is **not** enforced (the owner stops).
- **Roles.** Only the Implementer's container can change the tree; protected tests read-only; one run at a time; no
  agent tool is ever offered; a second CLI started inside the container shares its one mount, proxy and allowances.

## 3. Exceptions, said plainly

- **Not shown by anything here:** that a real model can do the work, real prices and rate limits, the real upstream's
  TLS, and DNS isolation on the operator's Docker version (the smoke repeats the network probe first).
- **The real-provider smoke**: PROPOSED, NOT RUN (owner-gated).
- **UX-C8, UX-C9**: NOT_RUN — deferred by the owner.
- **The engine not on in the operator's installation**: the launcher starts the helper without `--runner` (a smoke
  approval step, §2.6 of the proposal).
- **Residuals recorded, not fixed**: P4.R2 final review LOW R2F-L1 (`killThread` can exceed the 10 s shutdown if the
  worker is masked in a database call), R2F-L2 (Unicode-normalisation-only case collisions on APFS give spurious
  renames, never a link escape), R2F-L3 (absolute host paths of 920–1024 bytes halt instead of an early refusal); the
  live review's L4, L6, L8 and INFO items (dispositions in `docs/gates/P4.L.R1/contract.md` §5); from earlier: a
  submodule's own filters, migration 21 on a database with the race's duplicates, Git LFS stat changes.
- **Writer's slips, recorded**: the C-P4.L host check was reported as 86/86 in a commit message (`c7a6d54`): it has 84
  checks, corrected in the contract; the C-P4.L test modules were frozen before `hlint` ran on them (six style hints,
  ignored for those two modules only, tests unchanged); a broken log line in the helper during the P4.L.R1 trial made
  one full Mac run fail R-P1/R-P2 (found, fixed, the run repeated in full).
- **The P4.L.R1 changes** have not had a further independent review.
- **Known debt (owner, 2026-10-28)**: raw SQL and hand-built JSON in the existing layer; new work in this increment
  added no SQL and no JSON encoder (the provider line is plain text; no new persistence).

## 4. Decisions for the owner

1. Gate C-EXEC: accept / accept with exceptions / do not accept (candidate `d13ac33`).
2. Separately, the smoke's approvals, in order (`docs/gates/P4.L/real-provider-smoke-proposal.md` §2): the pricing
   basis; installation and the image; the credential (dedicated workspace, its own spend limit); the configuration;
   the helper with `--runner` (by hand, or a small launcher change); one smoke.
3. Whether the token limit is 3 000 000 all-inclusive (recommended) or 400 000 (an early stop), budget report §5.
4. Separately, UX-C8 and UX-C9 when you choose. Phase 5 and the dogfood project are not started.

## 5. Recommended disposition

**Accept with exceptions** (§3). Everything Phase 4 and this increment were asked to build is built, frozen first
against RED baselines, qualified on Mac and Linux and on the real Docker host, and independently reviewed; every
confirmed MEDIUM was corrected with a regression check before this packet. The live path is ready for the owner's
first, bounded smoke, which is the only remaining evidence that matters next.

## Appendix — Phase 4 as qualified before this increment (packet at `aba8b33`, candidate `54966a4`)

| Sub-phase | What | Frozen → implemented | Qualification |
|---|---|---|---|
| P4.1 | Allow Lockstep in a project (Bug Profile `lockstep-bug-fix` v1); hand over a ready task as a bug Work Order with no plan | `70b95d2` → `bd4512b` | Mac + Linux, `bd4512b` |
| P4.2 | Finite runners: direct process-group runner; the helper's container runner channel (`--runner`) | `b623d5d` → `ea9b445`, `b6385b6` (A-P4.2-1) | Mac + Linux, `b6385b6`; host container check 44/44 |
| P4.3 | Durable requests to a person and conversations; binding answers (person only, revision, once) | `ca44459` → `0fcb2b9`; A-P4.3-1 `4ee971d` | Mac + Linux, `4ee971d` |
| P4.4 | The Supervisor's Git boundary | `4785888` → `4f110cd` | Mac + Linux, `cbd7394` |
| P4.5 | Role invocation; strict answers; the scripted adapter | `d6319fd` → `6440ea5` | Mac + Linux, `cbd7394` |
| P4.6 | The transaction engine: basis, discovery, reproduction | `59d8517` → `cbd7394` | Mac + Linux, `cbd7394` |
| P4.7–P4.9 | Candidate tests, the challenge before the freeze (DG-07), the freeze | `be020cc` → `ef3c66b` | Mac + Linux, `30facae` |
| P4.10–P4.14 | One confined Implementer; verification; the challenge after it; independent review; compare-and-swap acceptance | `5fa1b15` → `0b8dbad` | Mac + Linux, `30facae` |
| P4.15 | A person's answer resumes or stops its own halt; Done or not, a person's only; the engine worker | `104fd2b` → `23e4bd5` | Mac + Linux, `d59aceb` |
| P4.16 | The task page: criteria → method → result → evidence, findings, review, not-known states, decisions | `1b86ee4` → `d59aceb` | as P4.15 |
| P4.R1 | The first review's M1–M5 and L6–L11 | `8f4361c` → `b77bc81` | Mac + Linux `54966a4` |
| P4.17 | End-to-end in a real browser (scripted roles); `lockstep serve` runs the engine worker with the helper's runner channel | `8f4361c` → `b77bc81` | Mac + Linux `54966a4` |
| P4.R2 | The second review's MEDIUM and LOW 2–6 | `1c52bb6` → `54966a4` | Mac + Linux `54966a4` |

All of the above is requalified at `d13ac33` by the full Mac and Linux runs. The deterministic scenarios (the
end-to-end browser journey, an incorrect fix rejected by an independent check, recovery at consequential points,
replay resistance, the production worker arrangement) use scripted roles: they show the orchestration, boundaries
and decision points, **not real model coding capability**.
