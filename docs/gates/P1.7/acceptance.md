# P1.7 acceptance record

- Contract: `C-P1.7@v1` (`contract.md`), frozen in `e350645`; tests unchanged since
- **Tested commit: `de8afa310e13a8d2b699ac4627afe092393b087a`** (`v2`, clean; fresh clones)
- Policy identity: manual — no v2 Supervisor
- Environment: macOS arm64, Docker Engine 29.4.0 via OrbStack; dev image `lockstep-dev:p1`
  (GHC 9.10.3); PostgreSQL `postgres:17.11-bookworm@sha256:3645570c…3826`; Chromium 155
- Schema revision: **5** (P1.7 adds no migration)
- Executed by: manual agent session (writing agent / Implementer), 2026-10-18
- Machine summary of the rows below: `PASSED`. **This is not acceptance.** Scenario A1 and
  Gate A are reported in `docs/gates/A/gate-report.md`.

| Criterion | Method | Expected | Actual | Disposition | Evidence |
|---|---|---|---|---|---|
| `AC-P1.7-01@v1` All six check steps from a fresh clone, step 5 included | `scripts/a1` step A1-01 (fresh clone of `de8afa3` → `scripts/check --integration`) | all PASSED, step 5 not NOT_RUN | format, lint, build, 259 unit, guard, 66 integration + backup/restore: PASSED | PASSED | `docs/gates/A/evidence/a1/check-fresh-clone.log` `fc7735e2…` |
| `AC-P1.7-02@v1` Same on a case-sensitive Linux filesystem | `linux-clone-run.sh` (names `-p17`) | 5 steps PASSED | format, lint, build, unit (259), integration (66): PASSED | PASSED | `evidence/check-linux-clone.log` |
| `AC-P1.7-03@v1` Frozen files intact; runner additive; no test change after the freeze | `shasum -c evidence/frozen-SHA256SUMS`; `git diff` | 37/37 OK; 0 removed lines; empty test diff `e350645..de8afa3` | as expected | PASSED | `evidence/sha-and-diff-checks.log` |
| `AC-P1.7-04@v1` Step 5 guard (E2, E3) | `scripts/check` step 5 | shims resolve before the tests (also inside `stack exec`); negative sentinel test; construction gate; fault-plan refusal; empty log after steps 4 and 6 | as expected | PASSED | fresh-clone log, step 5 section |
| `AC-P1.7-05@v1` Guard self-test (E5) | `check-guard-selftest` in step 5 | each of 5 failure modes fails the guard for its own reason | as expected | PASSED | same |
| `AC-P1.7-06@v1` Fault plans refused (E4) | frozen `FaultPlanTest` + guard (d) | exit 78, fixed stderr, empty stdout, never listens | as expected | PASSED | fresh-clone log |
| `AC-P1.7-07@v1` Installed service, loopback only (E6) | `scripts/service`; A1-04/04b | runs the installed binary with no repository mounted; only `127.0.0.1` listens; LAN refused | as expected | PASSED | `docs/gates/A/evidence/a1/a1.log` |
| `AC-P1.7-08@v1` Operator guide (E7) | inspection | install, DB operations, service lifecycle, sign-in, commands, evidence, troubleshooting | `docs/OPERATOR_GUIDE.md`; its procedures are the ones A1 runs | PASSED | `docs/OPERATOR_GUIDE.md` |
| `AC-P1.7-09@v1` A1 scripted run (E8) | `scripts/a1` | all checks PASSED | 17/17 PASSED (run `20261018T182651Z`) | PASSED | `docs/gates/A/evidence/a1/` |
| `AC-P1.7-10@v1` Gate A report and review (E10, E11) | inspection | report with per-criterion evidence and honest summary; review with dispositions | `docs/gates/A/gate-report.md`, `review.md`, `decision-packet.md` | PASSED | same |
| `AC-P1.7-11@v1` License policy | `scripts/licenses` | no new linked package | byte-identical to the P1.6 inventory | PASSED | `evidence/licenses.txt` |

## Log digests (SHA-256)

`evidence/SHA256SUMS`; verify with `cd docs/gates/P1.7/evidence && shasum -a 256 -c SHA256SUMS`.

## Deviations, corrections and recovery history

1. **E6 wording:** the Contract says Docker Desktop. The runtime on this host is **OrbStack**
   (Docker Engine 29.4.0). Loopback-only forwarding was measured on OrbStack (A1-04b), and the
   wording was corrected in `scripts/service` and the operator guide.
2. **E3 ordering, amended by the review (finding 4):** shim resolution is asserted before the
   unit and integration tests, inside `stack exec`, in addition to step 5. The test PATH is the
   shim directory plus the dev image's PATH, not a hand-built toolchain list (residual; Gate A
   report §3.8).
3. **Fixes after the implementation commit** (all after review or A1, before the tested commit):
   `1fa38e1` (A1 wrote into the repo while checking cleanliness); `60235ed` (review fixes:
   framing headers, sign-out 503, receipt abort, dispatcher logging, shim timing, regex, A1
   checks); `31d1626` (**attribute escaping**: Brigid 0.4's `A.value` does not escape); `de8afa3`
   (A1 logged raw session cookies: generic redaction, A1-14 fails on any raw value; sessions
   revoked; history redacted). A1 runs 1–3 are kept in `docs/gates/A/evidence/a1-history/`.
4. **Code outside P1.7's E-rows** touched by the review fixes: `Web/Operator.hs`,
   `Application/Command.hs`, `Application/Dispatcher.hs` (Contract §3 allows `src/**` "E4 only";
   these changes exceed that wording and are disclosed here for the owner). No frozen test
   changed. The full suite and A1 ran at the tested commit.
5. Operator state: the operator database is unchanged by P1.7 (schema 5). Four A1 databases
   `lockstep_a1_20261018t…` exist on the same server, with all sessions revoked.

## Decision

| Field | Value |
|---|---|
| P1.7 | **`VERIFIED — awaiting human acceptance`** at `de8afa310e13a8d2b699ac4627afe092393b087a` |
| Recorded by | manual agent session (writing agent / Implementer), 2026-10-18. Not an acceptance. |
| Gate A | Not decided. The owner decides it against the exact report revision (`docs/gates/A/decision-packet.md`). |

## Human acceptance (2026-10-18)

The human owner accepted P1.7, with its C-P1.7-R1 remediation, and Gate A on report r2. Recorded
by the writing agent (Implementer) at the owner's instruction; this is the owner's decision, not
the agent's. Owner's words, verbatim: "**P1.3–P1.7: ACCEPTED**, including the authorized
C-P1.7-R1 remediation, against their documented tested commits and Gate A r2 qualification
evidence."

| Field | Value |
|---|---|
| P1.7 | **ACCEPTED** |
| Tested commit | `de8afa310e13a8d2b699ac4627afe092393b087a` (this record); remediated and requalified at `6c2851d40a13be9ce08c97e692e30575b7b7d6e2` (`r1-acceptance.md`) |
| Gate A | **ACCEPTED** on report r2 (`docs/gates/A/r2/decision-packet.md`); report r1 is superseded and kept |
| Decided by | the human owner (operator), 2026-10-18 |
