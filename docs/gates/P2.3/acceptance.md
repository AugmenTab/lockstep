# P2.3 — verification record (C-P2.3@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `c9100c0` (implementation `d9fcc9d` plus
  the approved R-P2.3-1 test amendment). This is the writing agent's verification, not an
  acceptance.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-19.
- Contract: `contract.md` (FROZEN at `493036a`; R-P2.3-1 re-freeze in §10.1 at `c9100c0`).

## 1. Commits

| Commit | What |
|---|---|
| `3479f9a` | DG-05 and DG-04 recorded as ACCEPTED with the owner's clarifications |
| `493036a` | freeze: Contract, four test files, runner lines |
| `d9fcc9d` | implementation: `Lockstep.Kernel.Profile`, the document decoder, the registry (migration 0007), the CLI; R-P2.3-1 requested |
| `c9100c0` | R-P2.3-1 applied byte for byte after the owner's approval; re-frozen digest `c9ae6cea…` (tested commit) |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| F1–F2 fixed vocabularies, gate evaluation | PASSED | `ProfileTest` "definitions", "gates" |
| F3 clarification 1 (before-execution gates need pre-execution evidence) | PASSED | `gate-unsatisfiable-before-execution` cases; `executionPrerequisites` / `acceptanceGateIds` |
| F4 universal invariants | PASSED | `weakens-universal-invariant` cases; all nine in every effective Profile |
| F5 precedence, clarification 2 (unprovable strengthening refused) | PASSED | every single-axis `weakens-gate`; `unprovable-strengthening`; `profile-conflict` in both orders |
| F6–F7 trusted facts, clarification 4 (non-behavioural) | PASSED | `untrusted-classification`; `non-behavioural-refused` / `-violated`; `requiresFrozenTests` |
| F8 exceptions | PASSED | every exception refusal; `GateExcepted` |
| F9 binding and provenance | PASSED | `verifyProvenance` positive and three negative cases |
| F10 mid-flight change | PASSED | `ProfileChanged`, human confirmation, frozen Contract unchanged |
| F11–F12 rendering, digests, documents | PASSED | golden rendering; permutation invariance; `ProfileDocumentTest` |
| F13 registry immutability and integrity | PASSED | `ProfileRegistryTest`: SQL UPDATE/DELETE refused; tampered document → exit 70, no rendering |
| F14 CLI | PASSED | `CliProfileTest`; `ProfileRegistryTest` (real binary) |
| Frozen digests | PASSED | all frozen test files P1.1–P2.3 match their latest recorded digest (60 of 60); the additive runners match C-P2.3 |
| Kernel boundary | PASSED | purity scan clean (10 files, including `Profile`) |
| Licenses | PASSED | `scripts/licenses` output identical to P2.2 |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| Pre-freeze baselines | unit 74/451 fail, all new; integration 6/6 fail, all new | `evidence/prefreeze-*.log` |
| `scripts/check --integration` at `d9fcc9d` (unamended) | 451 unit; 78/79 integration (the R-P2.3-1 setup defect) | `evidence/check-integration-unamended.log` |
| `scripts/check --integration` with R-P2.3-1 (tree identical to `c9100c0` in `src`/`test`) | all 6 steps PASSED; 451 unit, 79 integration | `evidence/check-integration.log` |
| Linux clone at `c9100c0` | format, lint, build, unit, integration PASSED; 451 and 79; case-sensitive | `evidence/linux-clone.log` |

## 4. Notes for the owner

- Halt 1 (R-P2.3-1): one frozen test's setup sent three SQL statements in one prepared statement.
  The pre-freeze run never reached that line, and I had only read it. The amendment changed setup
  only. From P2.4 on, a fixture test exercises the test setup on its own before the freeze.
- Persisting a binding with its Work Order is C-P2.5; here the binding is a pure value.
- `profile resolve` is a dry run by the operator; it records nothing.
