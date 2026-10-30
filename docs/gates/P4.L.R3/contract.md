# Contract — P4.L.R3 Process isolation between the provider CLI and the processes running repository code

- Contract ID: `C-P4.L.R3@v1`
- Status: **FROZEN** (§5); amendment A-P4.L.R3-1 to `check-live-impersonation` **APPROVED by the Planner and
  applied** (§6)
- Authority: `.local/plans/phase-04_update5.md` (sha256 `b9147c0c…8cc158`), the P4.L.R3 process isolation handoff:
  close the remaining H2 vulnerability of `docs/gates/P4.L.R2/completion-packet.md` §7.
- Writer: the single writing agent (Implementer, manual). Basis: `phase-4` at `8c14bd5` (candidate `7018df9`), clean.
- Scope: the role container's process identities only. No change to the egress proxy, the budget ledger, the
  one-conversation rule, the Supervisor, the engine, the adapter's interface or the number of Implementers. No
  provider call, no real credential, no installation, no smoke.

## 1. The finding, as checked against `7018df9`

The CLI and every process its Bash tool starts run as the same user (the host's) in the role's container, and the
CLI is dumpable; the Docker VM's `kernel.yama.ptrace_scope` is 0. A program in the repository, run by the Bash tool,
can read the CLI's memory (`/proc/1/mem`, `process_vm_readv`), trace it (`ptrace`), take its descriptors
(`pidfd_getfd`, `/proc/1/fd`), read its environment and files, and signal it; with the latest tool-call id it learns
there, it continues the run's own conversation in the CLI's place for as many requests as the run's allowances permit
(`docs/gates/P4.L.R2/contract.md` §6, §9; `.local/p4lr2-h2-investigation.txt`). The baseline of §4 shows it with a
real memory scrape against secret ids (§5).

## 2. What the pinned CLI does (measured, Claude Code 2.1.312, `.local/p4lr3/`)

| # | Fact | How measured |
|---|---|---|
| F1 | Every Bash tool call starts the program named by `CLAUDE_CODE_SHELL_PREFIX` as the CLI's child, with **one argument**: the whole command string (`source <snapshot> … && eval '<command>' && pwd -P >\| /tmp/claude-XXXX-cwd`). The prefix runs it; its stdout and stderr are pipes to the CLI, its stdin a socket. | a logging prefix |
| F2 | `run_in_background` is not offered in this configuration (`InputValidationError`); no other path starts a tool process. | a scripted call |
| F3 | `Read` and `Edit` run inside the CLI. `Read` refuses `/proc/<pid>/…` ("a device or process file that this tool does not read"). | scripted calls |
| F4 | The CLI runs `git -c core.hooksPath=/dev/null -c core.fsmonitor= -C /work/tree ls-files …`, found on `PATH`; with no `git` on its `PATH` it carries on. | a logging `git` on `PATH`; a `PATH` without `git` |
| F5 | The CLI's private state is its `HOME` (`.claude/`, `.claude.json`, shell snapshots) and `/tmp/claude-<uid>/`; it listens on no socket (`/proc/net/tcp`, `/proc/net/unix`). | listings from a tool |
| F6 | The CLI runs normally when started with a real group different from its effective group (glibc secure mode) and with ambient capabilities. | the runs of §4 |

## 3. Decisions

| # | Decision |
|---|---|
| I1 | **Two identities in the role's container.** The **tools** (every process the Bash tool starts, so all repository code) run as the **host's user and group**, as every process there does today: what they write on the host belongs to the host's user. The **CLI** runs as a separate, fixed identity, uid `2000000000`, with the host's group as its effective group (files it makes are group-writable: umask `002`) and real group `2000000000`. |
| I2 | **Privileges dropped for good.** The container starts as root with only `CAP_SETUID`, `CAP_SETGID` and `CAP_DAC_OVERRIDE` (its bounding set) and no-new-privileges. `/opt/lockstep/agent-entry` (root, an instant): makes the tools' home `/tmp/home` (0700, the tools' identity) and the CLI's home `/tmp/agent` (0700, the CLI's identity), then executes the CLI through `setpriv` as uid `2000000000` with those three capabilities ambient. Each Bash call runs `/opt/lockstep/tool-shell` (F1), which closes every descriptor above 2 and executes `bash -c COMMAND` through `setpriv` as the tools' identity: all three user ids and group ids set, supplementary groups cleared, inheritable and ambient capabilities emptied (so permitted and effective are empty after the exec), no-new-privileges. The tools cannot get back: no capability, set-user-id programs and file capabilities ignored (no-new-privileges), a user namespace refused (Docker's seccomp). Their bounding set stays the container's three (dropping it needs `CAP_SETPCAP`, which nothing holds); with nothing permitted, inheritable or ambient and no-new-privileges it grants nothing. |
| I3 | **The CLI keeps its reach.** `CAP_DAC_OVERRIDE` lets the CLI's `Read` and `Edit` reach the run's tree, `/input` and `/output` (the host user's private 0700/0600 files) as before, with no change to their modes. Read-only mounts stay read-only for it (the protected files, a read-only role's tree: `EROFS`). |
| I4 | **The CLI is not dumpable.** Started with a real group different from its effective group, the kernel marks it not dumpable at exec: its `/proc/<pid>` entries belong to root, and nothing without `CAP_SYS_PTRACE` — not even a process of its own identity — can read its memory, descriptors or environment. A second wall behind I1, and the one that covers `tool-shell` itself. |
| I5 | **The CLI's surroundings.** `HOME=/tmp/agent`; `PATH=/usr/local/bin` (the CLI alone, so its own `git` call, F4, never runs code from the repository's configuration with its capabilities); `SHELL=/bin/bash`; `CLAUDE_CODE_SHELL_PREFIX=/opt/lockstep/tool-shell`; `CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=1` (each tool call starts in the tree). The tools get `HOME=/tmp/home` and the usual `PATH`. |
| I6 | **The helper.** A live role run (`run-live-readonly`, `run-live-write`) starts the provider image as `--user 0:0 --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE`, no-new-privileges, with `/opt/lockstep/agent-entry HOST-UID HOST-GID` before the service's argument vector; everything else (image, mounts, network, limits, environment, argument vector, the proxy) unchanged. Refused before anything starts, as `isolation-unavailable`: a host uid of 0 or `2000000000`, a host gid of `2000000000`. Scripted roles and every other container unchanged. |
| I7 | **Unchanged:** the egress proxy, the ledger, the one-conversation rule (H2), terminal refusals (H1), the modes (H3), the Supervisor, the engine, the adapter, the number of Implementers. |

## 4. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `scripts/lib/check-live-impersonation`, amended (A-P4.L.R3-1, §6) | host: real Docker, the real helper in its offline-test mode, the real Claude Code CLI | Section 1 as frozen (an impersonator handed the ids: fail-closed, the run's own ledger and allowances), its bound recorded as a note. **Section 2:** a stand-in with secret ids; a hostile program in the repository, run by the Implementer's Bash tool, denied each of `/proc/<cli>/mem`, `process_vm_readv`, `ptrace` attach and seize, `/proc/<cli>/environ`, `/proc/<cli>/fd`, `pidfd_getfd`, `/proc/<cli>/cwd`, the CLI's own files, the CLI's identity, a user namespace, a signal; learning no tool-call id; the CLI's conversation going on to its answer. With `--send`: **no impersonated request admitted**, the attempt ending the run `provider-stopped conversation-refused`, no answer, nothing but the CLI's opening upstream. Who runs what: the tools as the host's user and group with no capabilities and no-new-privileges; the CLI as another identity and not dumpable. Development across the two: the CLI edits the source; the tools append to a file the CLI made; the CLI edits a file the tools made; compile, test and `git commit`; the run exits 0 with its answer |
| `scripts/lib/live-standin-secret` | test tool | a stand-in upstream for the real CLI whose tool-call ids are fresh and random, playing scripted turns |
| `scripts/lib/live-memory-thief` | test tool | the hostile program: every path above, ids searched in ASCII and UTF-16, ids shipped in the CLI's program left out; optionally the impersonation |
| `check-live-boundary`, `check-live-concurrency`, `check-live-proxy`, `check-live-runner` (frozen, unchanged) | host | must stay green with the isolation: H1–H3, R2-H1, the proxy, the live runner (the protected files and the read-only role among them) |

Safety of the check: every run is submitted only after the helper names its offline-test mode; the upstream is a
stand-in on an internal network; the key is synthetic.

## 5. Freeze record

- Frozen 2026-10-30 by the single writing agent (Implementer, manual), on `phase-4` after `8c14bd5`, before any
  production change.

  | File | sha256 |
  |---|---|
  | `scripts/lib/live-standin-secret` | `4a3bf4a064ec1be4890c8b8e545651630c13693a603f1459407b025b9f8d2a35` |
  | `scripts/lib/live-memory-thief` | `95bbc88e35f338a8f5048e7ebbc4f16fa49a807f108862336c9eacfaa306ecaa` |
  | `scripts/lib/check-live-impersonation` (A-P4.L.R3-1, approved and applied) | `85b0a484f35421860fad8d97bc21616d4c2b306839657b2d5f01a226af44ae8d` |

- Baseline against `7018df9` (the amended check as a trial copy, the committed helper and image; no stubs):
  **16 failures, each the finding** (`.local/p4lr3-red-baseline.log`): a program in the repository read the CLI's
  memory and learned the run's random tool-call id, and its impersonated request was admitted. Details:
  `amendments.md`.

## 6. Amendment A-P4.L.R3-1 (the owner's authorization required)

See `docs/gates/P4.L.R3/amendments.md`.

## 7. Remaining limitations (stated plainly)

As amended by §10 (the review round): the CLI also holds `CAP_KILL` (four capabilities) and reads only its own
settings (`--setting-sources user`, added by agent-entry).

1. **The tools still reach the proxy.** A tool process can open a conversation of its own; it is refused and ends the
   run (C-P4.L.R2 H2, fail-closed). It cannot continue the run's conversation: it cannot learn the ids.
2. **The tools can still write the run's answer file.** `/output` is the host user's, as before R3; the answer is a
   claim the Supervisor verifies independently.
3. **The CLI's identity is privileged inside the container.** It holds `CAP_SETUID`, `CAP_SETGID`,
   `CAP_DAC_OVERRIDE`, `CAP_KILL` for the run. Code running as the CLI's identity (a defect in the CLI itself) defeats
   the boundary, as in any privilege separation. What could reach it is closed: the repository's settings are not read
   (§10 R3-M2); `git` is not on its `PATH`; its prefix and its homes are fixed by agent-entry.
4. **The tools' bounding set is the container's four capabilities.** Nothing is permitted, inheritable or ambient and
   no-new-privileges holds, so it grants nothing (measured); dropping it needs `CAP_SETPCAP`, which nothing holds.
5. **Host conditions.** Not dumpable needs `fs.suid_dumpable` 0 or 2 (with 1, live runs are off from the helper's
   start, and agent-entry refuses). `/tmp` symlink
   safety relies on `fs.protected_symlinks` (Docker's default). Docker with user-namespace remapping, or rootless
   Docker, is not supported: uid `2000000000` must be mappable. `--read-only` is load-bearing: with `CAP_DAC_OVERRIDE`
   the CLI could otherwise change `/opt/lockstep/tool-shell` or `/etc/hosts`.
6. **On a Linux host, files the CLI makes (through `Edit`) belong to uid 2000000000**, group the host user's, mode
   0664 (directories 0775): the host user can read, change and remove them, not `chmod` or `chown` them. On Docker
   Desktop (the Mac) bind mounts show them as the host user's. Live isolation is qualified on Docker Desktop only.
7. **Model-directed reads and writes.** A model steered by repository text can make the CLI's `Read` read the CLI's
   own files (its home). With `--no-session-persistence` no transcript is written and `Read` refuses `/proc`; no route
   to the ids through it is known. It can also make `Edit` write the CLI's own user settings; the pinned CLI does not
   reload them during the run (measured: a planted shell prefix and variable were not applied). A later CLI version
   that reloads settings would need this re-measured.
8. **`isolation-unavailable`** (a host uid of 0 or 2000000000) cannot be exercised on this host; it is a few lines,
   read by the review.
9. **The kernel is shared.** A kernel defect is out of scope.

## 10. The independent review and its regression (frozen before the fixes)

Review: `docs/reviews/phase-4-process-isolation-review-2026-10-30.md` — no HIGH, 2 MEDIUM, 7 LOW. Both MEDIUMs
measured by the writer before acting.

| # | Decision |
|---|---|
| R3-M1 | **The CLI may end its tools.** `CAP_KILL` joins the CLI's capabilities (helper and agent-entry); tool-shell's clearing keeps it from the tools. |
| R3-M2 | **The repository's Claude settings are never read.** agent-entry starts the CLI with `--setting-sources user` (its own private home only) before the service's arguments, and refuses an argument vector that names `--setting-sources` itself. A change of the image, not of the adapter: the service's argument vector, its fixture and its tests are unchanged. |
| R3-L1 | Ids are refused unless plain decimal without leading zeros (agent-entry, tool-shell). |
| R3-L2 | The frozen hostile program is unchanged; the regression requires each refusal to be the kernel's (`EACCES`, `EPERM`, `ESRCH`). |
| R3-L3 | agent-entry makes `/tmp/claude-2000000000` (0700, the CLI's) before the CLI starts. |
| R3-L4 | tool-shell sets umask 022 for the tools. Files the CLI makes stay the CLI's uid on a Linux host (group-writable for the host user): recorded in §7. |
| R3-L5 | agent-entry refuses to start (`isolation-unavailable` reason in its message) if `fs.suid_dumpable` is not 0; the other host conditions are named in §7. |
| R3-L6 | The helper turns live runs off at start if the image has no `/opt/lockstep/agent-entry` (an image built before R3). |
| R3-L7 | Recorded: `isolation-unavailable` cannot be exercised on this host (the helper does not run as root); the case is a few lines read by the review. |

Verification (frozen with this section):

| File | sha256 | Covers |
|---|---|---|
| `scripts/lib/check-live-isolation` | `8314a67197011c9a00321f903a376cfdd00e461c218361015afc338ad13931ee` | R3-L1 the entry refuses "00", "0UID", "02000000000"; R3-M1 a tool call timed out at 3 s writes nothing at 12 s, and the run goes on; R3-M2 a committed `.claude/settings.json` (a shell prefix and an environment variable) and a `settings.local.json` written during the run are not applied, the tools still run as the host's user, the run completes; R3-L2 each path of the hostile program refused by the kernel; R3-L3 the CLI's temporary directory is the CLI's, 0700; R3-L4 the tools' umask is 022 |

Baseline against `8444664` (`.local/p4lr3-review-red.log`): **8 failures, each its finding** — the three disguised
ids accepted; the timed-out call wrote `late.txt`; the repository's prefix ran in place of tool-shell, its
environment reached the tools, and the tools' command ran without the host's `id`; the tools' umask 0002. Passing
already: R3-L2 and R3-L3. One test fault fixed before this baseline: a planted `ANTHROPIC_BASE_URL` made the CLI retry
for minutes and starved the next scenario; left out (the same settings source is covered).

## 11. The confirming review

`docs/reviews/phase-4-process-isolation-fix-review-2026-10-30.md` (`08f2b91..9ed6b83`): M1, M2, L1, L3 closed; two
MEDIUM in the fix itself, both corrected before qualification:

| # | Decision |
|---|---|
| R3-F1 | **The image reports its isolation's version.** `agent-entry --check` prints `lockstep-isolation 2 ok` or `… refused REASON`; the helper requires exactly version 2 at start, else live runs are off with the reason (replaces R3-L6's file test, which an image from mid-round passed). |
| R3-F2 | **`fs.suid_dumpable` 0 or 2 accepted, 1 refused** (replaces R3-L5's 0 only), checked at the helper's start (through `--check`) and at each run's start. |
| R3-F3 | The helper's start says which: another isolation version; the host refused; the image could not report (with its exit status). |
| R3-F4 | A model-directed `Edit` of the CLI's own user settings during the run: measured not applied; §7 item 7. |

No new frozen check: R3-F1–F3 are the helper's start, which the live checks pass through on every run (they require
`live runs on (OFFLINE TEST`), and a host with `fs.suid_dumpable` 1 or an older image cannot be produced here without
changing the host or keeping a stale image; verified by reading and by the built image's answer.

## 8. Allowed paths

Production: `scripts/runner/provider/Dockerfile`, `scripts/runner/provider/agent-entry` (new),
`scripts/runner/provider/tool-shell` (new), `scripts/provider-image` (file modes), `scripts/control-helper` (the live
role run's container command and its refusal). Checks: the three files of §4. Documents: `docs/gates/P4.L.R3/`,
`docs/reviews/`, `docs/OPERATOR_GUIDE.md`, `docs/gates/P4.L/real-provider-smoke-proposal.md`,
`docs/gates/C-EXEC/decision-packet.md`.

## 9. Budget

One implementation pass; one review fix round if the review finds a HIGH or MEDIUM; stop and report if isolation
needs more than the role container's command and the provider image.
