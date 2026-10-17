# P1.2 acceptance record

- Contract: `C-P1.2@v1` (`contract.md`); tests frozen in `75599b0`, unchanged since
- Tested revision: `5d9f8e8a012d3301c6a19e67d28ba3722177ec44`, clean (fresh clones)
- Authority: ADR-0002 (DG-02) ACCEPTED 2026-10-17
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (+ `libpq-dev`), PostgreSQL
  `postgres:17.11-bookworm@sha256:3645570c…3826`, Docker 29.4.0, macOS arm64
- DB schema revision at the operator check: **1** (`lockstep_service_starts`)
- Executed by: manual agent session, 2026-10-17
- Machine summary of required rows: `PASSED`. Not acceptance by itself; see Decision.

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.2-01@v1` Steps 1–4 + integration from a fresh clone | `scripts/check --integration` in a clone of `5d9f8e8` | all PASSED | 90 unit + 29 integration tests; backup/restore check ok; step 5 NOT_RUN (P1.7) | PASSED | `evidence/check-fresh-clone.log` sha256 `d4bca33e…` |
| `AC-P1.2-02@v1` Same build on a case-sensitive Linux filesystem | clone inside the container | format/lint/build/unit PASSED | as expected | PASSED | `evidence/check-linux-clone.log` sha256 `5f3e6256…` |
| `AC-P1.2-03@v1` Fresh install, ordered migrations, no-op rerun | integration (real PG) + operator run | ledger = list in order; rerun applies nothing | as expected; `db status` revision none/pending 1 → revision 1/pending 0 | PASSED | fresh-clone log; `evidence/operator-run.log` sha256 `aff4f080…` |
| `AC-P1.2-04@v1` Refusals before any SQL: checksum, DB ahead, gap, invalid list; failed migration rolls back | unit + integration | typed refusal, ledger unchanged; failed DDL absent | as expected | PASSED | fresh-clone log |
| `AC-P1.2-05@v1` Concurrent runners apply once | integration, two pools | each migration once | as expected | PASSED | fresh-clone log |
| `AC-P1.2-06@v1` Missing/unavailable/misconfigured DB fails visibly and truthfully | integration + operator run | typed 503 reason; health 204; config errors exit 66 | not configured / unreachable / auth failed / missing / schema behind all distinct; DB stopped → 503 `database_unreachable`, page "Not ready" | PASSED | fresh-clone log; operator log |
| `AC-P1.2-07@v1` Restart and DB-backed projection | operator run + integration | starts persist across service and DB restarts | 1 → 2 → (DB restart) 3 → 4 | PASSED | operator log |
| `AC-P1.2-08@v1` Backup gate | integration (library) | refusals `BackupRequired`/`Missing`/`Stale`; fresh file or `--no-backup` proceeds | as expected (CLI exit 75 mapping not process-tested, as the Contract states) | PASSED | fresh-clone log |
| `AC-P1.2-09@v1` Backup / restore | `scripts/lib/check-db-backup-restore` + operator restore | round trip; corrupted dump refused | as expected; operator restore reset starts 4 → 0 (then 1) | PASSED | fresh-clone log; operator log |
| `AC-P1.2-10@v1` Secrets withheld | integration (password absent from outputs/pages) + log scan | no occurrence | 0 occurrences in all P1.2 evidence logs | PASSED | fresh-clone log; this record |
| `AC-P1.2-11@v1` Layering enforced | Henforcer: Foundation→Web and Web→Persistence fixtures | both rejected | as expected (Web→Persistence fixture added after the freeze, extra coverage) | PASSED | fresh-clone log |
| `AC-P1.2-12@v1` License policy after libpq | `scripts/licenses` | no unapproved linked package | 261 packages; only ADR-0003's exception; new **dynamic** system libraries via libpq listed (incl. LGPL GnuTLS, Nettle, libidn2, libunistring, libtasn1, keyutils), same category as glibc/GMP | PASSED | `evidence/licenses.txt` sha256 `cb97301a…`; `THIRD_PARTY_LICENSES.md` |

## Deviations and corrections (none touch a frozen test)

1. `recordServiceStart` returns `IO (Either NotReadyReason ())` instead of the
   Contract §4 `IO ()`, so a failure is reported (logged by `serve`) rather than
   thrown. No test binds to it.
2. Test suites use `henforcer-tests.toml` (same import rules, no layering rules):
   the frozen `Lockstep.Web.LivenessPageTest` imports Persistence types, and tests
   legitimately cross layers. `scripts/lib/check-henforcer-configs` keeps the two
   files identical apart from the layering block.
3. The forbidden-facility check now excludes all of `test/` (a frozen integration
   test names `rollbar` to prove it is refused).
4. Migrations run through libpq's simple-query protocol, because Orville always
   uses `PQexecParams`, which cannot run multi-statement SQL.
5. Two files were truncated by in-place formatting through the Docker Desktop bind
   mount; both were caught by the build and repaired; `scripts/format` now formats
   via stdin.
6. The Python checkout's ignored bytecode-cache directories under `src/Lockstep/`
   (left from branch `main`) were moved to `.local/python-src-leftovers/`; they
   case-collided with new module directories on macOS.

## Decision

| Field | Value |
|---|---|
| P1.2 | **ACCEPTED** under the Phase 1 handoff (sub-phase continuation). Its human decision (DG-02) was taken 2026-10-17. Gate A remains the human gate. |
| Recorded by | manual agent session, 2026-10-17 |
