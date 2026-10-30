# Independent review — P4.L.R3 process isolation (`8c14bd5..8444664`)

- Reviewer: an independent read-only agent (no edits, no runs), 2026-10-30. Scope: the privilege boundary of
  contract C-P4.L.R3 (agent-entry, tool-shell, the Dockerfile, the helper's live run, the checks).
- Verdict: **no HIGH; 2 MEDIUM; 7 LOW; INFO.** On H2: closed for the residual as stated (no tool process can read the
  CLI's state; I4 holds even against the CLI's own uid); not to be called complete until M1 is fixed and M2 measured.
- The writer measured both MEDIUMs before acting (`.local/p4lr3/run/script-m1`, `script-m2a`, `script-m2b`).

## MEDIUM

- **M1 — the CLI cannot kill its tools on a timeout.** tool-shell execs in place, so the pid the CLI holds is the
  host uid's; the CLI (uid 2000000000, no `CAP_KILL`) gets `EPERM`. *Measured:* a Bash call timed out at 3 s still
  wrote `late.txt` at 15 s.
- **M2 — the repository's own Claude settings are applied** (speculative in the review, existed before R3).
  `--bare` without `--setting-sources`: `.claude/settings.json`'s `env` may replace `CLAUDE_CODE_SHELL_PREFIX` (code
  as the CLI's identity with its capabilities) or `ANTHROPIC_BASE_URL` (the CLI's requests, ids included, to a
  listener of the tools). *Measured:* a committed `.claude/settings.json` replaced the prefix — the repository's
  script ran in place of tool-shell, as the CLI's uid — and its `env` reached the tools; settings written during the
  run were not reloaded. With `--setting-sources user` neither was applied.

## LOW

- L1 ids compared as strings in agent-entry/tool-shell ("00", "02000000000" pass).
- L2 the hostile program counts any exception as a denial.
- L3 the hostile program misses some places; `/tmp/claude-2000000000` could be squatted before the CLI makes it.
- L4 files the CLI makes belong to uid 2000000000 on a Linux host; tools inherit umask 002.
- L5 isolation depends on `fs.suid_dumpable` != 1, `fs.protected_symlinks`, and Docker without user-namespace
  remapping; nothing checks.
- L6 a provider image built before R3 (same tag) fails at launch, not at start.
- L7 `isolation-unavailable` is untested; the helper says live runs on even when every run would be refused.

## INFO (confirmed safe or by design)

ptrace/`process_vm_readv`/pidfd need ptrace access, `/proc/1/*` root-owned, signals fail on uid; tool-shell's window
with capabilities is not dumpable and bash ignores `BASH_ENV` there; setpriv sets saved ids; no-new-privileges and
seccomp block regaining; a pre-made `/tmp/agent` fails closed; `--read-only` keeps `/opt/lockstep` and
`/etc/hosts`/`resolv.conf` unwritable despite `CAP_DAC_OVERRIDE` (load-bearing); a model steered by repository text
can still read the CLI's own files through `Read` (no transcript is written; `/proc` refused); the three capabilities
go to any program in argv (argv is the adapter's); the contract's §7 still to be filled.

## Dispositions (the writer)

See `docs/gates/P4.L.R3/contract.md` §10.
