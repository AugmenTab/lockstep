# P1.6 acceptance record

- Contract: `C-P1.6@v1` (`contract.md`), frozen in `2dcdc46`; tests unchanged since
- **Tested commit: `2ac00597ff4d3bc92140a649c5aca71a420d5a56`** (`v2`, clean; fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (GHC 9.10.3), PostgreSQL
  `postgres:17.11-bookworm@sha256:3645570c…3826`, Docker 29.4.0, macOS arm64; Chromium 155 (screenshots)
- Schema revision after this sub-phase: **5** (migration `0005`, job outcome digests)
- Executed by: manual agent session (writing agent / Implementer), 2026-10-18
- Machine summary of the rows below: `PASSED`. **This is not acceptance.**

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.6-01@v1` Steps 1–4 + integration from a fresh clone | `git clone` of `2ac0059` → `scripts/check --integration` | all PASSED | format, lint/static checks, build, 259 unit, 62 integration, backup/restore: PASSED; step 5 NOT_RUN (P1.7) | PASSED | `evidence/check-fresh-clone.log` |
| `AC-P1.6-02@v1` Same on a case-sensitive Linux filesystem | `docs/gates/P1.3/evidence/linux-clone-run.sh` (names `-p16`) | 5 steps PASSED | format, lint, build, unit (259), integration (62): PASSED | PASSED | `evidence/check-linux-clone.log` |
| `AC-P1.6-03@v1` Frozen files intact; runners additive; no test change after the freeze | `shasum -c evidence/frozen-SHA256SUMS`; `git diff` | 36/36 OK; 0 removed runner lines; empty test diff `2dcdc46..2ac0059` | as expected | PASSED | `evidence/sha-and-diff-checks.log` |
| `AC-P1.6-04@v1` Evidence model rules 2–5 (E1, E2) | unit, incl. an exhaustive 160-combination check | effective PASSED iff complete, current, matching; worst-of aggregate; empty → NOT_RUN | as expected | PASSED | fresh-clone log |
| `AC-P1.6-05@v1` Not-run, failed, tampered or missing evidence never renders green (E3, E4) | unit rendering + integration + operator run | no `PASSED`/`ls-passed` for any non-PASSED effective row; edited row → `INCONCLUSIVE (evidence changed)`; cleared digest → `INCONCLUSIVE (incomplete evidence)` | as expected (operator run negative case; jobs finished before `0005` show `INCONCLUSIVE (incomplete evidence)`) | PASSED | fresh-clone log; `evidence/operator-run.log`; `evidence/screenshots/` |
| `AC-P1.6-06@v1` Page matches canonical rows (E5, E6) | integration + operator run | summary counts equal SQL counts; receipts and refusals listed | as expected | PASSED | same |
| `AC-P1.6-07@v1` A permitted operator action visibly changes the page (E7) | integration | queueing through the operator form raises `receipts:queued` by one and lists the receipt | as expected | PASSED | fresh-clone log |
| `AC-P1.6-08@v1` Not ready / no session (E9) | integration | 401 without a session; not-ready database → notice, no evidence rows, no PASSED | as expected | PASSED | fresh-clone log |
| `AC-P1.6-09@v1` Accessibility basics (E5, E8, NFR-12) | unit (CSS contrast ≥ 4.5:1 both themes, dashed NOT_RUN, green only on `.ls-passed`, `<th scope>` tables) + screenshot inspection | as stated | as expected; contrast 7.06–9.88:1 | PASSED | fresh-clone log; `evidence/screenshots/PROVENANCE.md` |
| `AC-P1.6-10@v1` Rendered UI inspected (E10) | headless Chromium screenshots (light/dark; operator DB and negative case), labelled and inspected | labelled `SCREENSHOT — shows rendering, not correctness`; inspection notes recorded | as expected | PASSED | `evidence/screenshots/PROVENANCE.md` |
| `AC-P1.6-11@v1` Migration `0005` behind the backup gate | integration + operator run | revision 4 + no flag → exit 75; with a backup → applies `0005` | as expected; operator DB migrated with `--backup .local/backups/20261018T173714Z-r4-58444.dump` | PASSED | same |
| `AC-P1.6-12@v1` License policy | `scripts/licenses` | no new linked package | output byte-identical to the P1.5 inventory | PASSED | `evidence/licenses.txt` |

## Log digests (SHA-256)

`evidence/SHA256SUMS`; verify with `cd docs/gates/P1.6/evidence && shasum -a 256 -c SHA256SUMS`.

## Deviations and notes (none touch a frozen test)

1. The evidence model lives at `Lockstep.Foundation.EvidenceModel` (VISUAL_EVIDENCE_CONTRACT §10
   names `Lockstep.Evidence.Model`), so the existing Henforcer layering covers it; recorded in E1.
2. Job evidence rows are judged against the current schema revision, so rule 4 (stale revision)
   cannot trigger for them yet; it is implemented and unit-tested for P1.7's gate rows.
3. Keyboard focus order and screen-reader output were not inspected by the agent; a human browser
   check belongs to A1 (P1.7).
4. A service started before its database is migrated runs no dispatcher until restarted (C-P1.5
   E4); the first operator-run pass showed this (documented in P1.7's operator guide).
5. Operator state: operator database at schema revision 5; job 6 (20 × 5 s) was returned to the
   queue when the capture stopped.

## Decision

| Field | Value |
|---|---|
| P1.6 | **`VERIFIED — awaiting human acceptance`** at `2ac00597ff4d3bc92140a649c5aca71a420d5a56` |
| Recorded by | manual agent session (writing agent / Implementer), 2026-10-18. Not an acceptance. |
| Continuation | Under the owner's instruction of 2026-10-18 ("Continue into P1.6 and P1.7 if all required checks pass"). |
