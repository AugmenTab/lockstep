# Completion packet — process isolation between the provider CLI and its tools (C-P4.L.R3)

- For: the owner and the Planner. Prepared 2026-10-30 by the writing agent (Implementer, manual) under
  `.local/plans/phase-04_update5.md` (sha256 `b9147c0c…8cc158`). The Implementer cannot accept Gate C-EXEC or mark
  anything Done.
- **H2 disposition: CLOSED** for the vulnerability the handoff names — a process started by the Implementer's tools
  can no longer read the CLI's memory, descriptors, environment or private files, so it cannot learn the run's
  conversation, and measured, **no** impersonated request is admitted (the owner's bound was one). Limitations that
  remain are in §7; none reopens it.
- **The real-provider smoke proposal is returned for the owner's authorization** (§9). Gate C-EXEC stays pending until
  a live transaction succeeds. Nothing was installed, no real credential exists, no provider was called.

## 1. HEAD, tree, diff

- Candidate: **`24cba9d`**; working tree clean at each qualification. Basis `8c14bd5` (candidate `7018df9`).
- Diff `8c14bd5..24cba9d`: 16 files, +1405 −23.
  - **Production:** `scripts/runner/provider/agent-entry` (new, 81 lines), `scripts/runner/provider/tool-shell` (new,
    28), `scripts/control-helper` (+39 −3: the live role container's command, its refusal, the image's isolation
    check at start), `scripts/runner/provider/Dockerfile` (+6), `scripts/provider-image` (file modes).
  - **Checks:** `check-live-isolation` (new), `live-memory-thief` (new), `live-standin-secret` (new),
    `check-live-impersonation` (A-P4.L.R3-1).
  - **Documents:** the contract, the amendment, two reviews, the operator guide, the smoke proposal.
- Commits:

  | Commit | What |
  |---|---|
  | `2474c64` | freeze (RED) |
  | `6f1de89` | the two identities |
  | `8444664` | A-P4.L.R3-1 applied |
  | `08f2b91` | the review's regression frozen (RED) |
  | `9ed6b83` | review fixes |
  | `24cba9d` | confirming-review fixes and documents |

- **Unchanged:** the egress proxy, the ledger, the one-conversation rule, the Supervisor, the engine, the adapter (its
  argument vector, fixture and tests), the number of Implementers.

## 2. What was built

Two identities in the live role's container (contract §3, §10, §11):

| | The tools (every Bash tool call, so all repository code) | The CLI |
|---|---|---|
| Identity | the host's user and group | uid `2000000000`, effective group the host's, real group `2000000000` |
| Privileges | none: no capabilities, no-new-privileges, umask 022, descriptors above 2 closed | `CAP_SETUID`, `CAP_SETGID`, `CAP_DAC_OVERRIDE`, `CAP_KILL` (ambient), to start and end its tools and reach the run's files |
| Traceable | — | **not dumpable** (real group ≠ effective group at exec): its `/proc` entries are root's, unreadable even to its own uid |
| Home, settings | `/tmp/home` (0700, its own) | `/tmp/agent` and `/tmp/claude-2000000000` (0700, its own); reads **only its own settings** (`--setting-sources user`), never the repository's `.claude` |
| Started by | `tool-shell` (the CLI's `CLAUDE_CODE_SHELL_PREFIX`), via `setpriv` | `agent-entry` (root, an instant, only those four capabilities), via `setpriv` |

The helper starts the container that way, refuses a host uid of 0 or `2000000000` (`isolation-unavailable`). At start
it requires the image to report `lockstep-isolation 2 ok` (else live runs off, with the reason: an older image, or a
host with `fs.suid_dumpable` 1).

## 3. Frozen-test amendment

A-P4.L.R3-1 (`check-live-impersonation`): **APPROVED by the Planner in full** (relayed by the owner, 2026-10-30) and
applied; sha256 `85b0a484…ae8d` equals the proposal (`docs/gates/P4.L.R3/amendments.md`). No other frozen test
changed.

## 4. RED/GREEN and digests

| Check | Frozen | sha256 | RED (baseline) | GREEN at `24cba9d` |
|---|---|---|---|---|
| `check-live-impersonation` (A-P4.L.R3-1) | `8444664` | `85b0a484…ae8d` | vs `7018df9`: 16 failures — a program in the repository **read the CLI's memory, learned the run's real random tool-call id and had its impersonated request admitted (200)** | **43/43** — every path refused, no id learned, the impersonated request refused (403), the run stopped fail-closed, development works |
| `check-live-isolation` | `08f2b91` | `8314a671…31ee` | vs `8444664`: 8 failures — a timed-out tool call kept running; a committed `.claude/settings.json` replaced the shell prefix (the repository's script ran as the CLI's identity) and its environment reached the tools; disguised ids accepted; tools' umask 002 | **26/26** |
| `live-standin-secret`, `live-memory-thief` | `2474c64` | `4a3bf4a0…2a35`, `95bbc88e…ecaa` | test tools | — |
| `check-live-runner`, `-boundary`, `-concurrency`, `-proxy` (unchanged) | earlier | as recorded | — | **84/84, 83/83, 17/17, 21/21** |

Evidence: `.local/p4lr3-red-baseline.log`, `.local/p4lr3-review-red.log`; GREEN runs in `.local/evidence/live-*-20261030t17…/`.

## 5. Qualification

- Mac `scripts/check --integration` at `24cba9d`: all six steps PASSED — unit **870/870**, integration **571/571**,
  backup/restore, no-live-model guard (sentinel log empty) (`.local/p4lr3-check-mac.log`).
- Linux clean clone at `24cba9d`: format, lint, build, unit and integration PASSED — unit **870/870**, integration
  **571/571**, case-sensitive disks (`.local/p4lr3-linux-rerun.log`). *Stated plainly:* the first Linux run at
  `24cba9d` had **one failure in 571**, `ReconciliationTest` "two processes recover one crashed idempotent intent"
  (`refused lease-active`, a legitimate outcome of two recoverers racing that the frozen P2.7 test does not list).
  That code is untouched here: no Haskell or database code changed. Repeated alone 10 times in a fresh Linux clone:
  30 of 30 passed (`.local/p4lr3-linux-race-repeat.log`). Then the full run was repeated and passed
  (`.local/p4lr3-linux.log` is the first run). Recorded as a timing race in a frozen test, for the owner's attention;
  not changed.
- Host, real Docker, at `24cba9d`:
  - the six live checks above, all green;
  - `check-runner`: 0 failures;
  - `check-runner-paths`: 7/7;
  - `lockstep-stress`: PASS.

  Evidence: `.local/evidence/runner-20261030t200957z/`, `.local/evidence/runner-paths-20261030t201028z/`,
  `.local/p4lr3/host-stress.log`.
- An earlier full Mac run at `6f1de89` (before the review fixes) passed: unit 870/870, integration 571/571.
- Environment note: this Mac's Docker had nearly exhausted its pool of network address ranges (other projects'
  networks). `check-live-boundary` then fails its seven CLI cases at launch (`egress-failed`, no container created).
  Unused networks left by Lockstep's own test runs were removed, and it passed. It is not a product fault, but an
  operator can meet it; see §7.

## 6. Independent reviews

1. `docs/reviews/phase-4-process-isolation-review-2026-10-30.md` (`8c14bd5..8444664`): **0 HIGH, 2 MEDIUM, 7 LOW**.
   - M1 — the CLI could not end its tools on a timeout; measured.
   - M2 — the repository's Claude settings were applied: a committed `.claude/settings.json` replaced the shell prefix.
     This existed before R3 but bypassed the new boundary; measured.

   Both were fixed with a frozen regression, as were L1, L3, L4, L5 and L6; L2 is covered by the regression; L7 is
   recorded (contract §10).
2. `docs/reviews/phase-4-process-isolation-fix-review-2026-10-30.md` (`08f2b91..9ed6b83`): M1, M2, L1, L3 **CLOSED**.
   Two MEDIUM in the fix itself were corrected before qualification:
   - the image check required only a file, so an image from mid-round passed;
   - `suid_dumpable` 2 was refused.

   Also a misleading message, and a measured model-directed settings write (contract §11).

## 7. What remains (stated plainly; contract §7)

1. **Tools can still reach the proxy.** A conversation of their own is refused and ends the run (fail-closed, as
   before). They cannot continue the CLI's.
2. **Tools can still write `/output`,** as before R3. The answer is verified independently.
3. **The CLI's identity holds four capabilities for the run.** A defect in the CLI itself would defeat the boundary.
   What could feed it is closed: no repository settings, no `git` on its `PATH`, a fixed prefix.
4. **Host conditions.** `fs.suid_dumpable` must be 0 or 2 (checked). `fs.protected_symlinks` and `--read-only` are
   relied on. Docker without user-namespace remapping, and not rootless. **Qualified on Docker Desktop (Mac) only.**
5. **On a Linux host, files the CLI creates belong to uid 2000000000** (the host user's group, 0664).
6. **A model steered by repository text can read and write the CLI's own files** through Read and Edit. No transcript
   is kept, `/proc` is refused, and a settings write is not reloaded by the pinned CLI (measured). A later CLI version
   must be re-measured.
7. **`isolation-unavailable` is not exercised here** (the helper does not run as root).
8. **Docker's network address pool on the operator's machine.** A live run needs one network of its own; the offline
   checks need up to three.

## 8. Confirmations

- Installation: **none** (the operator's installation, service, helper and launcher unchanged).
- Real credentials: **none** (synthetic `sk-ant-test-…` keys only, made and removed by the checks).
- Live provider calls: **none** (every upstream a local stand-in on an internal network; no-live-model guard clean).
- Production engine enabled: **no**. Real coding transaction: **none**. The smoke: **not run**. Nothing pushed.
- Docker housekeeping on this Mac: removed only Lockstep's own unused test networks (`lockstep-test-1878-25052`,
  `lockstep-test-74311-10017`, `lockstep-linux-cr1`) and one container of a superseded Linux run. Other projects'
  networks and containers were not touched. The provider image `lockstep-provider:claude-2.1.312` was rebuilt
  locally (not published).

## 9. Decisions for the owner

1. **H2:** accept the disposition (closed, with §7's limitations).
2. **The real-provider smoke** — the revised proposal `docs/gates/P4.L/real-provider-smoke-proposal.md`, its approvals
   in order:
   - the pricing basis;
   - installing the candidate and building the image from it;
   - the credential;
   - the configuration;
   - the helper with `--runner`;
   - one attended smoke on a disposable repository.

   Two pre-flight checks are added: `check-live-isolation` and `check-live-impersonation` on the operator's Docker,
   and `fs.suid_dumpable`.
3. Gate C-EXEC remains pending until a live transaction succeeds. Phase 5 and the dogfood project are not started.
