# Halts and what a retry does (stabilization S2, handoff §3.2)

A halted transaction resumes only by a person's answer to its decision request. *Retry* puts the transaction back
into the **same stage**, which then runs from its start at a new revision (`stepTransaction`, `HumanRetry`). What
actually executes again is therefore the stage's own work. Since S2 the halt's question and page say it
(`retryOperation`).

| Stage | A retry executes | Can the outcome differ? |
|---|---|---|
| basis | the Supervisor's ownership and basis checks, then the work branch | yes, once the operator fixes the folder (dirty, missing, not a repository) |
| discovery | the Planner's discovery (a new model run) | yes |
| reproduction | the discovery's reproduction command, at the same basis | only by chance: **no longer offered** after a command that did not reproduce (see below) |
| candidate | the Planner's candidate tests (a new model run), then their baseline | yes |
| challenge-pre | the Challenger on the tests (a new model run) | yes |
| freeze | the Supervisor's freeze commit | yes, after a transient Git failure |
| implement | the Implementer (a new model run) | yes |
| verify | the verification commands in the verification environment | yes, once the environment is fixed |
| challenge-post | the Challenger on the change | yes |
| review | the Reviewer | yes |
| accept | the Supervisor's acceptance commit (compare-and-swap) | yes, after a transient Git failure |

## Halt classes

| Class | Halts | Choices |
|---|---|---|
| Retryable transient | `supervisor-failed …`, `baseline-run-failed`, `verification-run-failed`, `role-failed role-crashed`, `role-failed role-timed-out`, `provider-stopped …` | retry, stop |
| Missing required input (operator fixes, then retries) | `repository-dirty`, `repository-missing`, `not-a-repository`, `verification-environment-missing`, `role-failed provider-auth-rejected` (sign in again or decide S1-SD1), `role-failed no-coding-agent` | retry, stop |
| Replanning required | `reproduction-missing` (a supplied command did not reproduce) | accept-non-reproduction, **replan**, stop |
| Explicit human decision | `finding-needs-human`, `review-needs-human` (including an incomplete review, S3), `candidates-exhausted`, `attempts-exhausted`, `green-regression-failed` | retry (the role runs again), stop |
| Permanent for this transaction | `protected-test-changed` at verify (the same candidate commit would be verified again and found again) | **stop only** (review finding 1) |
| A refusal with its own code (`HaltRefused`) | at basis: ownership or repository refusals the operator can fix; at candidate: scope refusals of the Planner's answer, where a retry runs the Planner again; at verify or candidate: `verification-environment-missing` and the like, fixable in the environment | retry, stop — a retry either runs a role again or re-checks a condition the operator can change |
| Unknown external effect | `uncertain-invocation …` (a role whose end is unknown) | retry, stop — never run by itself (E4); a retry runs the role once more at a new revision, in a fresh workspace, and its earlier run's tree is discarded |

## The ineffective retry that was removed

`reproduction-missing` with the Planner's `reproduction` absent (`command = null`) offered *retry*, which re-entered
the reproduction stage and re-checked the same absent command: it could never change anything (the Brigid run,
intervention 6). Since S2 that case does not halt at all (`reproduction-omitted`, on to the candidate tests). When a
supplied command does not reproduce, re-running the same command at the same basis is not offered; *replan* runs the
Planner's discovery again instead, and *accept-non-reproduction* goes on to the tests, which must still be RED.

Decision requests already opened before S2 keep the choices they were opened with. Answering *retry* on such an old
`reproduction-missing` now re-runs the reproduction stage under the new rule: with no command it proceeds.

## Unchanged guarantees

- Nothing is retried by itself; only a person's answer to the current halt's own request resumes it.
- An invocation whose outcome is unknown is never replayed by itself (E4, C-P4.R1, C-P4.R2).
- The candidate and implementation budgets (corrections ≤ 2, attempts ≤ 2) are unchanged.
