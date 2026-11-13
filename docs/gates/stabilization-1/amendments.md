# Amendments to frozen tests for C-STAB-1 (S2)

- **Authority:** `.local/plans/phase-05_update4.md` §3.1–§3.3, owner-approved: "A separate reproduction command may
  be omitted. A genuine failing RED baseline may not." and "If existing frozen tests encode the contradictory
  behavior, follow the established amendment/supersession procedure. This handoff authorizes the specific semantic
  correction above, not arbitrary removal of reproduction safeguards."
- **Applied by:** the Implementer, only the lines that encode the contradiction. No other frozen file changed.
  `TransactionTest.hs` (C-P4.6) is **not** amended: its rules still hold (a `NotReproduced` input still halts
  `reproduction-missing`; a person's retry is still a legal Kernel input there — the decision request simply no
  longer offers it).
- **Superseded in part:** DG-06 D-6.6 / C-P4.6 E7 "no command … → halted `reproduction-missing`" (decision register,
  "Stabilization S2").

## A-STAB-1 — `test/integration/Lockstep/EngineTest.hs` (C-P4.6, frozen `8035cd9a…`)

| | sha256 |
|---|---|
| Frozen (P4.6 freeze record) | `8035cd9a2c0e978b90eec9f0e7636482378bcee58fe3ae68e04a29424e3d2994` |
| Amended | see `amendment-digests.txt` |

Changes, all in the `notReproduced` case:

1. Its name: "a command that passes, or none at all, is reproduction-missing; only then is accepting it offered" →
   "a command that passes is reproduction-missing, where accepting it or a replan is offered; none at all goes on to
   the tests".
2. The choices at `reproduction-missing`: `accept-non-reproduction, retry, stop` → `accept-non-reproduction, replan,
   stop` (S2.3: the retry there could only re-run the same command at the same basis).
3. No command at all: was halted `reproduction-missing`; now the input is `reproduction-omitted`, no halt, at
   `candidate` (S2.1).

Unchanged in it: a passing command is still `not-reproduced` and halts `reproduction-missing`; the reproduction,
discovery, crash, cut-short and immutability cases.

## A-STAB-2 — `test/integration/Lockstep/EngineHumanTest.hs` (C-P4.15, frozen `55ec4df6…`)

| | sha256 |
|---|---|
| Frozen (P4.15 freeze record) | `55ec4df6b6b467ddd2d8ba3e60cb3bc4e10f30f0c9d9d8f5f59d0600f15ad68c` |
| Amended | see `amendment-digests.txt` |

Changes, in the `nonReproduction` case only:

1. The halt is reached with a command that runs and does not reproduce (`python3 -c 'print(1)'`, as in EngineTest),
   instead of with no command (which no longer halts, S2.1).
2. Its choices: `accept-non-reproduction, retry, stop` → `accept-non-reproduction, replan, stop`.

Unchanged in it: a person's accept-non-reproduction resumes at `candidate`; stop stops for good; every other case.

## What the RED rule still enforces (not weakened)

The candidate stage is untouched: a candidate reaches the challenge only if every test is classified `red-confirmed`
or `green-confirmed` and at least one is `red-confirmed` (it fails at the basis, not with 126/127, with its
signature in its output). Wrong-reason, unexpectedly-passing and GREEN-only candidates go back to the Planner within
the correction budget, then halt `candidates-exhausted`. Covered after an omission by
`StabilizationReproductionTest` cases 4–6 and `ReproductionRetryTest`.
