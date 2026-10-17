# P1.1 acceptance record

- Contract: `C-P1.1@v1` (`contract.md`); tests frozen in `f2154cf`, unchanged since
- Tested revision: `86d96de835209acf23586031c3219c15b55b3f20`, clean (fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: dev image `lockstep-dev:p1` (Debian 12 `bookworm-slim@sha256:7c7b2c96…`,
  GHC 9.10.3, Stack 3.7.1, Cabal 3.14.2.0, fourmolu 0.18.0.0, HLint 3.10), Docker 29.4.0
  on macOS arm64
- Executed by: manual agent session, 2026-10-17
- **Status: NOT ACCEPTED.** Machine summary of required rows: `BLOCKED` (row 08).

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.1-01@v1` AC-P0-05 passed before any import | `git ls-remote`/bare clone, tree hash, `diff -r` | identical trees | `2d3f3d7c…` both; diff empty; done before first Launchpad-derived file | PASSED | `evidence/AC-P0-05-provenance.md` |
| `AC-P1.1-02@v1` `scripts/check` steps 1–4 from a fresh clone | `scripts/check --integration` in `git clone` of `86d96de` | steps 1–4 PASSED | 1–4 PASSED (40 unit tests); step 5 NOT_RUN (P1.7) | PASSED | `evidence/check-fresh-clone.log` sha256 `eaaa3327…b468` |
| `AC-P1.1-03@v1` Same on a case-sensitive Linux filesystem | clone inside the container, `scripts/lib/check-step` each step | all PASSED | format, lint, build, unit, integration PASSED | PASSED | `evidence/check-linux-clone.log` sha256 `97142f81…fea5` |
| `AC-P1.1-04@v1` Serves 204 + liveness page on 127.0.0.1; not reachable on non-loopback | `lockstep-integration` (real process, TCP) | 204; page; external connect refused | 5/5 OK incl. default port 8000, SIGTERM exit 0, `serve --port` exit 64 | PASSED | same log, step 6 |
| `AC-P1.1-05@v1` Forbidden template facilities absent | `scripts/lib/check-forbidden-facilities` + unit route/asset tests | no match; removed routes 404 | none in 28 files; 9 removed routes 404; Pico/hyperscript assets 404 | PASSED | same log, steps 2 and 4 |
| `AC-P1.1-06@v1` Henforcer boundary enforced | negative fixture + positive control | violation rejected (HEN-49096), control compiles | as expected | PASSED | same log, step 3. Kernel/Persistence/Effects/Application rows: NOT_RUN (no such modules) |
| `AC-P1.1-07@v1` Partial-function lint in force | negative fixture | 17/17 flagged | 17/17 flagged; production code: no hints | PASSED | same log, step 2 |
| `AC-P1.1-08@v1` (AC-P0-08) Transitive licenses acceptable; GMP linkage recorded; notices present | `scripts/licenses`, symbol search | no unapproved copyleft linked | 254 packages inventoried; GMP **dynamic** (`libgmp.so.10`); **`iso3166-country-codes` LGPL-3.0 statically linked via Brigid** | **BLOCKED** — needs the ADR-0003 decision | `evidence/licenses.txt` sha256 `b306502b…504a`; `THIRD_PARTY_LICENSES.md` sha256 `d2b0861f…c8c8`; `docs/adr/ADR-0003-…` |
| `AC-P1.1-09@v1` `allow-newer` only as approved (D9) | static check | scoped to `integer-types`, `libphonenumber` | as expected | PASSED | `evidence/deps-resolve-allow-newer-false.log`; contract D9 |

Deviations: D9 (scoped `allow-newer`, human-approved 2026-10-17). Defects found and
fixed before acceptance, none in frozen tests: case-insensitive path capture
(`src/lockstep` vs `src/Lockstep`, now checked), the hlint `head` ban catching
Brigid's `E.head` (rules now module-qualified), and a truncated file from an
interrupted formatter run.
