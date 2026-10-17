# P1.1 + P1.2 acceptance packet (recovery R1)

- Purpose: the evidence for the human owner's acceptance of P1.1 and P1.2 at
  one exact commit (recovery plan `.local/plans/phase-01-recovery.md` §3, §7.3).
- **Tested commit: `b3a37233e2077de6a196112a2ef46780b71a30bb`** (`v2`, clean),
  "docs(p1.1,p1.2): correct self-recorded acceptance (manual)"
- R1 commits: `eb78032` (C-P1.2-R1 test amendment), `4c38ab5` (forbidden-facility
  exclusion narrowed), `b3a3723` (acceptance-record corrections)
- Production code: **unchanged since `5d9f8e8`** (the P1.2 implementation).
  `git diff --stat 5d9f8e8 b3a3723 -- . ':!docs' ':!test'` lists only
  `scripts/lib/check-forbidden-facilities`.
- Schema revision: 1 (`lockstep_service_starts`)
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (GHC 9.10.3, Stack 3.7.1), PostgreSQL
  `postgres:17.11-bookworm@sha256:3645570c…3826` (disposable), Docker 29.4.0, macOS arm64
- Executed by: manual agent session (writing agent), 2026-10-17
- Machine summary of the rows below: `PASSED`. **This is not acceptance.**

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-R1-01@v1` Steps 1–4 + integration from a fresh clone | `git clone` of `b3a3723` → `scripts/check --integration` | steps 1–4 and 6 PASSED | format, lint/static checks (forbidden facilities: none in 55 files), build (`-Werror`, Henforcer, boundary fixtures rejected), 90 unit, 29 integration, backup/restore check: all PASSED; step 5 NOT_RUN (P1.7) | PASSED | `evidence/r1/check-fresh-clone.log` |
| `AC-R1-02@v1` Same on a case-sensitive Linux filesystem | clone inside the dev container, `scripts/lib/check-step` format, lint, build, unit, integration (disposable PG on a private network) | all PASSED | all 5 PASSED; 90 + 29 tests | PASSED | `evidence/r1/check-linux-clone.log` |
| `AC-R1-03@v1` Frozen files intact | `shasum -a 256 -c` against C-P1.1 §8 (minus the two runners), C-P1.2 §8 (minus `ServiceDbTest.hs`) and C-P1.2 §9.1 | 20/20 OK | 20/20 OK | PASSED | `evidence/r1/sha-verify.log` |
| `AC-R1-04@v1` Runner edits additive only | `git diff f2154cf -- test/unit/Main.hs test/integration/Main.hs` | no removed line | 0 removed lines | PASSED | `evidence/r1/diff-checks.log` |
| `AC-R1-05@v1` Test changes since the P1.2 freeze are exactly R1 + the known fixture | `git diff 75599b0 -- test/` | the C-P1.2-R1 hunks and `test/fixtures/boundary/violation-web-persistence/…` only | exactly those (2 files, +23 −3) | PASSED | `evidence/r1/diff-checks.log` |
| `AC-R1-06@v1` R1 fix works for a later migration | scratch clones (not committed) with a dummy migration `0002`; only the `ServiceDbTest` group run against a disposable PG | commit-3 version green; `75599b0` version fails on its literals | commit-3: 6/6 passed; `75599b0`: 2/6 failed (`revision 1` not found; `schema_behind 1` vs `2`) | PASSED | `evidence/r1/dummy-migration-scratch.log` |
| `AC-R1-07@v1` Narrowed forbidden-facility check still enforces | scratch: `rollbar` added to `test/unit/Lockstep/Web/ServerTest.hs`; then in a new file under `test/fixtures/`; clean tree | non-zero, non-zero, zero | exit 1, exit 1, exit 0 (at commit 3; also before commit 2 with the old script as control: old script passed the fixture case) | PASSED | `evidence/r1/forbidden-negative-commit3.log`, `evidence/r1/forbidden-negative.log` |
| `AC-R1-08@v1` Operator run and license evidence still apply | digests of the existing P1.2 evidence; no production code change since `5d9f8e8` | digests match the P1.2 record | match | PASSED | `evidence/operator-run.log`, `evidence/licenses.txt` |

## Log digests (SHA-256)

| File | SHA-256 |
|---|---|
| `evidence/r1/check-fresh-clone.log` | `255cb9e3801dc10bd96d4d1a9b7be97f2b925b973a0ccd0aacf6f0b0ae65b67c` |
| `evidence/r1/check-linux-clone.log` | `f7d9f78632bee38629bd96e00dcf88039952e9935e1c44760a1767fe98abdf6b` |
| `evidence/r1/diff-checks.log` | `493b0a681e3d173e36733a4300ff46e0b4a01c69b2959349ce875bbe28377251` |
| `evidence/r1/dummy-migration-scratch.log` | `57bcfc19d0e1e67383014cb707e79ca8dcfbf10816c132dc66ade243e7004fe4` |
| `evidence/r1/forbidden-negative-commit3.log` | `237aad3e069209b636dd25645a6e2757d2a220a1dc5592a1bbaaad9cbbe981e3` |
| `evidence/r1/forbidden-negative.log` | `2227f2c3f865ce48afe431a911fdd55a663f5cd394c1b6e1cdcd188d5755bd7d` |
| `evidence/r1/sha-verify.log` | `86268052a024aae607266f378d515aea55cb7118995c7b24c505d22b14e5fbce` |
| `evidence/operator-run.log` (P1.2, unchanged) | `aff4f080d25f1460fb4696a8b299e18dcc6c73b07baa0f35d8c557ccab8cbcb3` |
| `evidence/licenses.txt` (P1.2, unchanged) | `cb97301ac92c6ad469351ad78504aa015e9b164ce0be1fcf746aca6b5c18b4b7` |

`evidence/r1/SHA256SUMS` holds the R1 digests; verify with
`cd docs/gates/P1.2/evidence/r1 && shasum -a 256 -c SHA256SUMS`.

## Notes and limitations

- Step 5 (no-live-model guard) is NOT_RUN by design until P1.7.
- The CLI exit-75 mapping of the backup gate is not process-tested (as C-P1.2 states).
- The handoff and recovery plan cite line 49 for the `schema_behind` literal; it
  was on line 47 (C-P1.2 §9).
- Ratified deviations, the not-ratified forbidden-facility exclusion and the
  withdrawn self-acceptance are recorded in `docs/gates/P1.1/acceptance.md` and
  `docs/gates/P1.2/acceptance.md` (Correction sections) and C-P1.2 §9.2.

## Decision

| Field | Value |
|---|---|
| P1.1 | |
| P1.2 | |
| Decided by | |
| Date | |
| Notes | |
