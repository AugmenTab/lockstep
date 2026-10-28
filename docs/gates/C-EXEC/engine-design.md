# Phase 4 engine design (the single-Engineer coding transaction)

- Status: working design of the writing agent, 2026-10-28, inside the accepted DG-06, DG-07, DG-17 decisions
  (`DECISION_REGISTER.md`, `.local/plans/phase-04_update1.md`). Each sub-phase Contract (C-P4.x) narrows and
  freezes its part; where a Contract and this note differ, the Contract wins.
- Purpose: one place that says how the parts fit, so each Contract stays small.

## 1. Shape

One **transaction** per admitted bug Work Order (C-P4.1 admission). It runs stage by stage; every stage
is durable, so a restart resumes at the stage it was in and never repeats an invocation whose outcome is
unknown.

```
basis → discovery → reproduction → candidate (≤3) → challenge-pre → freeze →
implement (≤2) → verify → challenge-post → review → accept → (human) done
                         any stage → halted (human request, P4.3/P4.15) → resume | stop
```

| Stage | Who acts | What happens | Sub-phase |
|---|---|---|---|
| basis | Supervisor | the project's repository is still the owned one (C-P4.1), its main worktree is clean, `HEAD` is a commit; it becomes the **basis**; branch `lockstep/<work-order>` is created at it (refused if it exists) | P4.4 |
| discovery | Planner (read-only) | summary, root-cause hypothesis, source citations, a reproduction argv with a failure signature, allowed implementation paths | P4.5, P4.6 |
| reproduction | Supervisor | runs the reproduction argv at the basis; the signature must appear and the command must fail; otherwise blocked (human exception only, D-6.6) | P4.6 |
| candidate | Planner | Contract (criteria citing the Ticket and source), verification argv, test files each RED or GREEN-REGRESSION with argv and signature; host checks paths and citations, runs the baseline at the basis and classifies (D-6.1); ≤2 correction rounds | P4.8 |
| challenge-pre | challenger (read-only, no transcripts) | findings; a mutant is run against the candidate tests in a scratch snapshot; a demonstration check is run on the mutant | P4.7 |
| freeze | Supervisor | commits the tests on the branch with its own identity; records digests and the Contract digest; the Kernel Work Unit is frozen (`WuFreeze`) | P4.9 |
| implement | Implementer | a Git-free writable snapshot of the freeze tree, protected tests read-only; the host checks the change set (D-17.2) | P4.10 |
| verify | Supervisor | the candidate commit object is written by the Supervisor (not on any branch); a fresh snapshot of it runs the verification argv and every frozen test | P4.11 |
| challenge-post | challenger | counterexample tests run against the candidate in a scratch snapshot | P4.12 |
| review | Reviewer (read-only) | verdict on the exact candidate commit, Contract, evidence and findings | P4.13 |
| accept | Supervisor | every condition holds → `update-ref` of the branch from the freeze commit to the candidate commit (compare-and-swap) | P4.14 |
| done | Human only | the person reads the evidence and marks it done, or not | P4.16 |

## 2. Boundaries

- **Runner** (P4.2). One interface, `RoleRunner`, two implementations with the same request and result:
  - *container* (production; DG-17 D-17.1(a)): the service writes a signed `run` request to the host helper's
    runner channel; the helper runs `docker run` from a fixed table (pinned image, non-root, `--read-only`,
    `--cap-drop ALL`, `no-new-privileges`, `--pids-limit 256`, 4 GiB, 2 CPUs, `--network none`, mounts only
    the run's own `tree`, `input`, `output`, protected files read-only on top), bounded time and output.
  - *direct* (the deterministic suite and development): the same request run as a local process group with an
    explicit environment, no inherited descriptors, `/dev/null` input, bounded time and output, the whole group
    killed. It gives no network or filesystem confinement and is refused for a live provider.
- **Git** (P4.4). Only the Supervisor touches the canonical repository, only through plumbing with a private
  index (`read-tree`, `hash-object -w`, `update-index`, `write-tree`, `commit-tree`, `update-ref` with the old
  value). The person's working tree and index are never touched. Snapshots are written from `ls-tree`/
  `cat-file` of an exact commit, without `.git`.
- **Roles** (P4.5). A role gets an input document and returns one JSON document on `/output/result.json` (at
  most 256 KiB). Parsing is strict; anything else is `malformed-output`. Repository text is data, never
  instructions. Adapters: *scripted* (model-free; a fixed program in the runner reads a script provided by the
  qualification harness) and *claude* (constructed only in `Lockstep.Effects.Provider.Live`; not invoked
  without the owner's separate authorization).
- **Uncertainty**. An invocation is recorded `started` before it runs and `finished` after. A `started` one found
  at restart is `uncertain`: the transaction halts with a human request and never re-runs it by itself.

## 3. Records

- `lockstep_transactions`: one per Work Order; stage, state (`running`, `halted`, `accepted`, `done`,
  `stopped`), counters, basis, branch, freeze and candidate commits; changed only under a row lock with its
  version.
- `lockstep_transaction_records`: immutable typed documents (discovery, reproduction, contract, candidate
  tests, baseline, finding, freeze, implementation, verification, review, acceptance, halt, resume, done),
  each with its SHA-256.
- `lockstep_invocations`: every role invocation and command run: what, limits, runner, started/finished,
  outcome, byte counts, output digests and bounded tails.
- `lockstep_work_unit_steps`: the Supervisor commands given to the Kernel Work Unit (`stepWorkUnit`), replayed
  on read, so its accepted rules (budget, basis match, gates before review) hold.

The Ticket and Work Order ledgers are not advanced by the transaction: `TicketWorkAccepted`,
`TicketIntegrated` and `WoComplete` with units are not durable in the frozen C-P2.2 codec. The human Done of
Phase 4 is recorded on the transaction (Human principal only). Making those ledger events durable is a later
amendment, not done silently here.

## 3a. Transaction rules (pure Kernel, P4.6 onward)

- Inputs come only from the Supervisor (observations of what a stage did) or a Human (resume with a
  choice, stop, done); an Agent is never accepted. The Kernel decides the next stage and the counters.
- **Role invocations** are the only steps never re-run by themselves: recorded `started` before, `finished`
  after; a `started` one found later is `uncertain` → halted with a human request (`retry` or `stop`).
  Supervisor Git steps are deterministic (same commit for the same inputs, compare-and-swap refs) and
  commands run in fresh snapshots, so both may simply run again after a crash.
- **Baseline (DG-06 D-6.1)** per candidate test at basis + candidate tests: RED needs a failing exit, not
  126/127, its signature **and** its identity (the test file's stem) in the output → `red-confirmed`;
  passing → `red-unexpectedly-passed`; failing otherwise → `red-wrong-reason`; GREEN passing →
  `green-confirmed`, failing → `green-candidate-failed` (a defective new fixture: correctable with this
  evidence, never relabelled RED); the run itself timed out, too much output, launch failed →
  `run-failed` (never RED). The Contract's verification commands at the basis (the project's own suite) must
  pass, else `green-regression-failed`: a pre-existing failure, hard stop for a human.
- **Corrections (D-6.4)**: at most 2 (3 candidates); correctable: the red/green classes above and a
  `CONFIRMED` challenge finding; not correctable: `green-regression-failed`, a scope violation, an
  environment failure.
- **Challenges (DG-07 as clarified)**: a mutant is applied to a scratch snapshot (basis + candidate tests,
  or the candidate implementation post-implementation) and the candidate tests run; the mutant *survives* if
  they all pass. `CONFIRMED` needs a surviving mutant **and** its demonstration check failing on the mutant
  with its signature (pre-freeze), or a supplemental test failing on the implementation with its signature
  (post-implementation), **and** a requirement reference that names a Contract criterion (or the Ticket
  before a Contract exists). A killed mutant is `DISPROVED`. Anything else is `INCONCLUSIVE`, or
  `NEEDS_HUMAN` when the challenger asks for a person. `NEEDS_HUMAN` blocks (human request); `INCONCLUSIVE`
  is shown at Done.
- **Attempts**: at most 2 Implementer attempts; a second only after a typed failure (change refused, a
  verification failure, a `CONFIRMED` post-implementation finding, a Reviewer rejection), with that
  feedback. Exhausted → halted for a human.
- **Kernel Work Unit**: the transaction also drives `stepWorkUnit` (C-P2.2) with Supervisor commands:
  `WuFreeze` (Contract digest, budget 2, the Bug Profile's acceptance gates), `WuStartAttempt`,
  `WuImplementationObserved <candidate commit>`, `WuVerificationObserved`, `WuGatePassed` per gate with its
  evidence, `WuReviewObserved`; acceptance requires its `Accepted` state.

## 4. Limits (DG-17 D-17.7)

Implementer 20 min; Planner, challenger, Reviewer, verification and reproduction 10 min each; stdout 8 MiB,
stderr 2 MiB; 256 processes, 4 GiB, 2 CPUs. Implementer attempts ≤ 2; candidates ≤ 3; one challenge per
candidate and per implementation; one review per implementation.
