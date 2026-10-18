# P1.5 acceptance record

- Contract: `C-P1.5@v1` (`contract.md`), frozen in `73d5b57`; amended by the human owner on
  2026-10-18 (§9: A1 queue-form placement, A2 no-op lease, A3 = R-P1.5-1 test amendment,
  re-frozen in `5ce9d00`)
- **Tested commit: `10a849d1ba067fce3676796d021523da3fd2bc58`** (`v2`, clean; fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (GHC 9.10.3), PostgreSQL
  `postgres:17.11-bookworm@sha256:3645570c…3826`, Docker 29.4.0, macOS arm64
- Schema revision after this sub-phase: **4** (migration `0004`, background jobs)
- Executed by: manual agent session (writing agent / Implementer), 2026-10-18
- Machine summary of the rows below: `PASSED`. **This is not acceptance.**

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.5-01@v1` Steps 1–4 + integration from a fresh clone | `git clone` of `10a849d` → `scripts/check --integration` | all PASSED | format, lint/static checks, build, 230 unit, 58 integration, backup/restore: PASSED; step 5 NOT_RUN (P1.7) | PASSED | `evidence/check-fresh-clone.log` |
| `AC-P1.5-02@v1` Same on a case-sensitive Linux filesystem | `docs/gates/P1.3/evidence/linux-clone-run.sh` (names `-p15`) | 5 steps PASSED | format, lint, build, unit (230), integration (58): PASSED | PASSED | `evidence/check-linux-clone.log` |
| `AC-P1.5-03@v1` Frozen files intact; the only test change after the freeze is R-P1.5-1 | `shasum -c evidence/frozen-SHA256SUMS`; `git diff 73d5b57` | 33/33 OK; 0 removed runner lines; test diff = the authorized diff, byte for byte | as expected | PASSED | `evidence/sha-and-diff-checks.log` |
| `AC-P1.5-04@v1` Admission is separate from execution (E1, E2, E6) | integration + operator run | CLI/HTTP only queue (job stays `queued` with no service); a replay gives one job | as expected (operator run: `queued steps 0/3 attempts 0` before `serve`; replay `(replayed)`, one job) | PASSED | fresh-clone log; `evidence/operator-run.log` |
| `AC-P1.5-05@v1` The service executes in the background; HTTP never waits (E4, E7) | integration + operator run | job succeeds under `serve`; HTTP queue answers 303 before the work; a disconnected client loses nothing | as expected (operator run: browser queue 303 in 11 ms, job later `succeeded 5/5`) | PASSED | same |
| `AC-P1.5-06@v1` Deterministic failure, not retried | integration + operator run | `failed steps 1/3`, `error: deterministic failure injected at step 2`, attempts 1 | as expected | PASSED | same |
| `AC-P1.5-07@v1` Restart and crash recovery (E5) | integration + operator run | SIGTERM returns the job to the queue and a restart resumes from `steps_done` (attempts 2); after SIGKILL the job is reclaimed when the lease expires (`recovered 1`) | as expected (operator run: `running 4/10` → SIGTERM → `queued 4/10` → restart → `succeeded 10/10 attempts 2`) | PASSED | same |
| `AC-P1.5-08@v1` Two services, each job once | integration | every job `succeeded` with attempts 1 and steps 3 | as expected | PASSED | fresh-clone log |
| `AC-P1.5-09@v1` Migration `0004` behind the backup gate | integration + operator run | revision 3 + no flag → exit 75; with a backup → applies `0004` | as expected; operator DB migrated with `--backup .local/backups/20261018T171735Z-r3-54788.dump` | PASSED | same |
| `AC-P1.5-10@v1` Secrets withheld | operator run | DB password and sign-in token absent from all outputs and server logs | 0 and 0 | PASSED | `evidence/operator-run.log` |
| `AC-P1.5-11@v1` License policy | `scripts/licenses` | no new linked package | output byte-identical to the P1.4 inventory | PASSED | `evidence/licenses.txt` |

## Log digests (SHA-256)

`evidence/SHA256SUMS`; verify with `cd docs/gates/P1.5/evidence && shasum -a 256 -c SHA256SUMS`.

## Recovery history (this sub-phase)

1. First full run at `7eb31b1`: 8 integration tests failed in the frozen `DispatcherTest`
   (start-up helper defect): `evidence/check-working-tree-red.log`.
2. Scratch runs with a proposed test fix (not committed) found an implementation bug, fixed in
   `71b6be0` (dispatcher now stops on SIGTERM before Warp's graceful wait), and a second test
   defect (connection churn): `evidence/scratch-run-1…4-*.log`.
3. The human owner approved R-P1.5-1 and ratified the queue-form placement and the no-op lease
   (`decision-request.md`, "Human decisions", 2026-10-18). The authorized diff was applied
   unchanged and re-frozen (`5ce9d00`, C-P1.5 §9).

## Known issue

C-P1.5 §9.2: the frozen P1.2 helper `Support/Postgres` opens a connection pool per query and
never closes it, so fast polling can exhaust PostgreSQL connections. Recorded, not fixed (owner's
instruction: no refactor of accepted P1.2 tests unless correctness requires it).

## Notes

1. `Lockstep.Web.Server` gained `serverSettingsWith` (an `IO ()` run first on SIGTERM);
   `serverSettings` is unchanged for the frozen `ServerTest`.
2. The claim/lease/resume rules apply to the model-free no-op kind only and do not decide DG-04
   (Contract header; owner's A2 wording).
3. Operator state: the operator database is at schema revision 4 after the operator run; it holds
   jobs 1–4 (one deterministic failure).

## Decision

| Field | Value |
|---|---|
| P1.5 | **`VERIFIED — awaiting human acceptance`** at `10a849d1ba067fce3676796d021523da3fd2bc58` |
| Recorded by | manual agent session (writing agent / Implementer), 2026-10-18. Not an acceptance. |
| Continuation | Under the owner's instruction of 2026-10-18 ("Continue into P1.6 and P1.7 if all required checks pass"). |
