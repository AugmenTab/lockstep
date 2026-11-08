# Confirming review — P4.L.R3 review fixes (`08f2b91..9ed6b83`)

- Reviewer: an independent read-only agent (nothing run, edited or written), 2026-10-30. Scope: the fix commit
  answering `docs/reviews/phase-4-process-isolation-review-2026-10-30.md`.
- Status of the first review's findings: **M1 CLOSED, M2 CLOSED, L1 CLOSED, L3 CLOSED**; L4 and L5 PARTIAL as decided
  (recorded in the contract §7); L6 PARTIAL (finding 1 below).

## Findings

1. **MEDIUM — the stale-image probe checked only that `agent-entry` exists.** An image built between `6f1de89` and
   `9ed6b83` (likely on this machine during the work) has an `agent-entry` without `CAP_KILL` in its bounding set and
   without `--setting-sources`: the probe passes, M1 and M2 silently unfixed. *Fix:* a version the image reports and
   the helper requires.
2. **MEDIUM — `fs.suid_dumpable` 2 refused as well as 1.** With 2 the kernel keeps a changed-credential process's
   dumps root's, and `ptrace_may_access` still refuses without `CAP_SYS_PTRACE`; Ubuntu hosts with apport set 2, so
   every live run there would fail at launch while the helper says live runs on. *Fix:* accept 0 or 2; check at the
   helper's start.
3. **LOW — any Docker failure of the probe was logged as "predates the isolation".** Fail-closed, misleading.
4. **LOW (speculative) — the model, steered by repository text, could write the CLI's own user settings
   (`/tmp/agent/.claude/settings.json`) through `Edit`;** if the CLI reloaded them mid-run, their `env` could replace
   the shell prefix.
5. **INFO** — the argument refusal scans the prompt too (cannot match the fixed prompt); `set -eu` reads fail closed;
   the probe's flags match the helper's other probes; gid 0 for the tools accepted as before.

## Dispositions (the writer)

| # | Disposition |
|---|---|
| 1 | **Fixed.** `agent-entry --check` prints `lockstep-isolation 2 ok` (or `… refused REASON`); the helper requires exactly version 2 at start, else live runs off with the reason. An image from before this change answers otherwise and turns live runs off. Verified: the built image answers `lockstep-isolation 2 ok`; the older images were already pruned, so the stale path is verified by reading only. |
| 2 | **Fixed.** 0 and 2 accepted, 1 refused, both in `agent-entry --check` (live runs off at the helper's start, with the reason) and at each run's start. |
| 3 | **Fixed.** Distinct log lines: another isolation version; the host refused (with the reason); the image could not report (with the exit status). |
| 4 | **Measured, recorded.** An `Edit` of `/tmp/agent/.claude/settings.json` during the run (a shell prefix and a variable) was not applied: the next tool call ran as the host's user through tool-shell, the variable absent, the planted prefix never ran (`.local/p4lr3/run/script-usersettings`). Recorded in the contract §7 (a model-directed write, not reloaded by the pinned CLI). |
