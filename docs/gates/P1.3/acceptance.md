# P1.3 acceptance record

- Contract: `C-P1.3@v1` (`contract.md`), frozen in `1f2445b`; tests unchanged since
- Decisions: the human owner's D-1a, D-2d, D-3a (`decision-request.md`, "Human decisions")
- **Tested commit: `d2f04eac088d002d6c2a0e5c386c9cadd7873d57`** (`v2`, clean; fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (GHC 9.10.3), PostgreSQL
  `postgres:17.11-bookworm@sha256:3645570c…3826`, Docker 29.4.0, macOS arm64
- Schema revision after this sub-phase: **2** (migration `0002`, operator tokens and sessions)
- Executed by: manual agent session (writing agent / Implementer), 2026-10-17
- Machine summary of the rows below: `PASSED`. **This is not acceptance.**

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.3-01@v1` Steps 1–4 + integration from a fresh clone | `git clone` of `d2f04ea` → `scripts/check --integration` | all PASSED | format, lint/static checks, build (`-Werror`, Henforcer, boundary fixtures), 172 unit, 39 integration, backup/restore: PASSED; step 5 NOT_RUN (P1.7) | PASSED | `evidence/check-fresh-clone.log` |
| `AC-P1.3-02@v1` Same on a case-sensitive Linux filesystem | `evidence/linux-clone-run.sh` (clone inside the dev container; disposable PG) | 5 steps PASSED | format, lint, build, unit (172), integration (39): PASSED | PASSED | `evidence/check-linux-clone.log` |
| `AC-P1.3-03@v1` Frozen files intact; runner changes additive; no test change after the freeze | `shasum -c evidence/frozen-SHA256SUMS`; `git diff` | 26/26 OK; 0 removed runner lines; empty test diff `1f2445b..d2f04ea` | as expected | PASSED | `evidence/sha-and-diff-checks.log` |
| `AC-P1.3-04@v1` Sign-in token issue (E2) | integration + operator run | one URL line, empty stderr, digest only stored, ≈5 min; not ready → 69; no config → 66 | as expected; operator run: schema behind → exit 69 `not_ready schema_behind 1` | PASSED | fresh-clone log; `evidence/operator-run.log` |
| `AC-P1.3-05@v1` Confirm page (E3, D-2d) | unit + integration + operator run | 200, `no-store`, `Referrer-Policy: origin`, the CSP, token once in a hidden input, nothing external | as expected | PASSED | same |
| `AC-P1.3-06@v1` Exchange and session (E4, E5, D-3a) | integration + operator run | atomic consume + session, 303 → `/operator`, cookie `HttpOnly; SameSite=Strict; Path=/; Max-Age=43200`, no `Secure`; reuse/expired/unknown → 403; two concurrent → one 303 | as expected | PASSED | same |
| `AC-P1.3-07@v1` CSRF, sign-out, sign-out-all (E6, E8, E9) | integration + operator run | missing/wrong `csrf` → 403 and session intact; sign-out 303 + cleared cookie; then 401; sign-out-all counts live sessions | as expected (operator run: `revoked sessions: 1`) | PASSED | same |
| `AC-P1.3-08@v1` Request guard (E7, D-1a, D-2d) | unit (guard + app) + integration + operator run | foreign/localhost Host → 403; missing Host refused on operator/mutating routes only; missing/foreign/`null` Origin → 403, no exception; unrouted → 404 first; frozen P1.1/P1.2 tests unchanged and green | as expected | PASSED | same |
| `AC-P1.3-09@v1` Malformed input never 500 | integration | garbage/over-long cookie, non-UTF-8 body, missing field, 200 kB body → 4xx | as expected | PASSED | fresh-clone log |
| `AC-P1.3-10@v1` Bounded token exposure; DB password withheld (E11) | integration (every test, server log included) + operator run | raw token only in the CLI line, the GET URL and once in the confirm body; password nowhere | integration green; operator run: 0 token occurrences in all headers, server log, CLI stderr and other bodies; 0 password occurrences | PASSED | same |
| `AC-P1.3-11@v1` Migration `0002` under the backup gate (ADR-0002) | integration + operator run | revision 1 + no flag → exit 75, nothing applied; with a fresh backup / `--no-backup` → applies `0002` | as expected; operator DB migrated with `--backup .local/backups/20261017T201125Z-r1-49664.dump` | PASSED | same |
| `AC-P1.3-12@v1` Browser behaviour for D-2d | Chromium 155 + Firefox ESR 153.5 probe | exact Origin on the POST; Referer origin-only; no token outside the GET request line | as expected | PASSED | `evidence/referrer-origin-probe.log` |
| `AC-P1.3-13@v1` License policy | `scripts/licenses` | no new linked package or exception | output byte-identical to the P1.2 inventory | PASSED | `evidence/licenses.txt` |
| `AC-P1.3-14@v1` Layering and paths | Henforcer (build step); `git diff --stat 1f2445b d2f04ea` | no config change; only Contract §3 paths | as expected (Foundation `OperatorToken`, `Config`, `Cli`; Persistence `OperatorSessions`, `Migrations`; Application `OperatorTrust`, `Database`; Web `RequestGuard`, `Operator`, `Application`; `Main`, `package.yaml`, `lockstep.cabal`, `README.md`) | PASSED | `evidence/sha-and-diff-checks.log` |

## Log digests (SHA-256)

`evidence/SHA256SUMS`; verify with `cd docs/gates/P1.3/evidence && shasum -a 256 -c SHA256SUMS`.

| File | SHA-256 |
|---|---|
| `evidence/check-fresh-clone.log` | `080ef9c0d1d18ed6c5209df4b9443176c7adbfbd970d07e01e896ce687d2e60b` |
| `evidence/check-linux-clone.log` | `82c3edd22d1ec2f91c1d7448babc6302b574990b4e579f56f7bca497cd40df44` |
| `evidence/sha-and-diff-checks.log` | `f96ca845171e4220f33f0e6ae38e5f8a4f3210db36d11d933fb9abc899b020d6` |
| `evidence/operator-run.log` | `369144614b853fad7753c1891e384b550180134394fdb867d0e3eac5c76a472b` |
| `evidence/licenses.txt` | `cb97301ac92c6ad469351ad78504aa015e9b164ce0be1fcf746aca6b5c18b4b7` |
| `evidence/referrer-origin-probe.log` | `ed6e49337300e35090ffd7d38fec58cf477608826eb50acfb3f2d54054e6a2e4` |
| `evidence/prefreeze-stub-build.log` | `3ebec4ceb2962b820192a9862e1df8f069164d11a47f400d9c519a72040a21fb` |
| `evidence/prefreeze-baseline.log` | `82b58f5c08ea8f0b8b62b9c34c66c5350a79d333b3f3f90df7a3c0924aa3c495` |
| `evidence/frozen-SHA256SUMS` | `f5b5f09d30846ba90d9fb4bbd37d604aef4a2ef2b7bc0d035afd2bfb27116cf4` |

## Deviations and notes (none touch a frozen test)

1. Contract §4 named `data Session`; it is a `newtype` with the same field. `RouteClass` has
   two constructors, as the frozen Contract states for D-2d.
2. `Lockstep.Application.Database` now also exports `withDatabase` (used by `OperatorTrust`);
   no behaviour change.
3. Form field names are written with Brigid's `customAttribute`, which avoids a direct
   `non-empty-text` dependency for `A.name`; dependencies are exactly E13's (`memory`, `cookie`).
4. Before the freeze, three draft-Contract points were tightened (E4 400/413 handling, E9
   "unrevoked and unexpired", E13 without `base64-bytestring`); they are part of the frozen
   text and no test changed afterwards.
5. A real-browser run of the full flow belongs to P1.7 (A1), as the Contract states; D-2d's
   browser behaviour is covered by the probe (row 12).
6. Operator state: the operator database `lockstep-postgres` is now at schema revision 2,
   migrated with the backup above (pre-migration restore point, ADR-0002).

## Decision

| Field | Value |
|---|---|
| P1.3 | **`VERIFIED — awaiting human acceptance`** at `d2f04eac088d002d6c2a0e5c386c9cadd7873d57` |
| Recorded by | manual agent session (writing agent / Implementer), 2026-10-17. Not an acceptance. |
| Continuation | The owner's instruction of 2026-10-17 ("proceed sequentially through P1.3–P1.7 … Do not request ceremonial approvals") lets work continue to P1.4 while this record awaits the owner. |

## Human acceptance (2026-10-18)

The human owner accepted P1.3 with Gate A r2. Recorded by the writing agent (Implementer) at the
owner's instruction; this is the owner's decision, not the agent's. Owner's words, verbatim:
"**P1.3–P1.7: ACCEPTED**, including the authorized C-P1.7-R1 remediation, against their
documented tested commits and Gate A r2 qualification evidence."

| Field | Value |
|---|---|
| P1.3 | **ACCEPTED** |
| Tested commit | `d2f04eac088d002d6c2a0e5c386c9cadd7873d57` (this record); qualified with Gate A r2 at `6c2851d40a13be9ce08c97e692e30575b7b7d6e2` (`docs/gates/A/r2/gate-report.md`, sha256 `33c8d26a0b7a01696fc1e2b4c3f2541fd7062a2d18f60616cc0da895520feaef`) |
| Scope | as recorded above, including the 2026-10-18 correction |
| Decided by | the human owner (operator), 2026-10-18 (`docs/gates/A/r2/decision-packet.md`) |
