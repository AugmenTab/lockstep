# P2.9 Contract — Gate B qualification (scenario B1)

- Contract ID: `C-P2.9@v1`
- Status: **FROZEN** (2026-10-19): the criteria of §3 are fixed. `scripts/b1` implements them;
  a defect in the script may be fixed, but a criterion is never weakened, and every run is kept.
- Basis: `v2` at the P2.8 record (`P2.8 VERIFIED — awaiting human acceptance`, browser check
  pending); C-P2.1–C-P2.8.
- Authority: `.local/plans/phase-02.md` §13 (P2.9) and §15. Gate B acceptance belongs only to
  the human owner: this sub-phase stops at the decision packet and does not begin Phase 3.
- Traces: TESTING_STRATEGY §2.1, §5 ("in-memory substitutes are not acceptable evidence for Gate
  B"), §11 (evidence conventions); VISUAL_EVIDENCE_CONTRACT §3–§7 (the report); the Gate A
  precedent (C-P1.7 E8, E10; `scripts/a1`).
- Writer: the single writing agent (manual).

## 1. Objective

Run scenario B1 end to end against real PostgreSQL and the actual installed service. Record
every command and its evidence. Write a Gate B report and a short decision packet for the owner.
Nothing in B1 calls a model, a provider or the network beyond loopback.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| Q1 | **`scripts/b1`** runs B1 in the `scripts/a1` style. From a fresh clone of the tested commit it runs `scripts/check --integration`, then `scripts/service install`. It creates a **fresh database** `lockstep_b1_<UTC stamp>` on the operator PostgreSQL server and runs the installed service as a **separate container** `lockstep-b1` on `127.0.0.1:8200`, with provider-CLI sentinel shims first on its `PATH`. Every command is recorded with argv, exit code and output digests, and tokens and session values are redacted. The B1 database is kept for inspection. The owner's operator database and `lockstep-service` container are not touched. |
| Q2 | **Repositories** are created and registered inside one container of the installed image running the installed binary: the installed service mounts no host repositories (C-P2.1). That container also attempts the collisions; the ownership record persists in the B1 database. |
| Q3 | **Crashes** are real: a `supervisor execute-once` container is killed (`docker kill`, SIGKILL) once its sandbox effect is visible at the destination. Restarts are `scripts/service restart` of `lockstep-b1`. Lease ends are waited for, never forced by SQL. |
| Q4 | **The browser**: `/operator/ledger` is loaded after sign-in in headless Chromium (`test/browser/cdp.py`). This closes the P2.8 browser check. |
| Q5 | **Gate B report** `docs/gates/B/gate-report.md` (VISUAL_EVIDENCE_CONTRACT §3–§7). It has a header (repository, branch, tested commit, clean flag, schema revision, policy identity `manual — no v2 Supervisor`, governing document digests from `SOURCE_REGISTER.md`), one row per criterion `AC-B1-NN@v1`, the P2.1–P2.8 status table with their records, an honest machine summary (the worst required effective disposition, labelled "not acceptance"), known limitations, and a decision block only the owner fills in. A short `docs/gates/B/decision-packet.md` links them. |
| Q6 | **Independent read-only review** (`docs/gates/B/review.md`): a separate reviewer agent with no edit, write, build, Docker or network use, reading files and read-only git only, over the Phase 2 diff. It is not a human review. The writing agent records each finding's disposition and leaves items needing the owner to the owner. |
| Q7 | **Green only if** every required criterion is `PASSED`: no required check skipped, no effect outcome left unknown without an authorized resolution, and repository exclusivity established (plan §13). Otherwise the summary says what is not. |

## 3. Criteria (normative)

| ID | Statement | Required |
|---|---|---|
| AC-B1-01@v1 | A fresh clone of the tested commit passes `scripts/check --integration`: format, lint and static checks (including the Henforcer negative fixtures), build with the Kernel purity scan, unit (including the property and trace suites), the no-live-model guard, and integration with backup/restore (real PostgreSQL, real crashes, real worker processes). | yes |
| AC-B1-02@v1 | The release binary is installed from a clean checkout of the tested commit (`VERSION`: that commit, `dirty false`). | yes |
| AC-B1-03@v1 | A fresh database migrates to revision 12 (migration 0012, C-P2.9-R1 M8) and reports `readiness ready 12`. | yes |
| AC-B1-04@v1 | The installed service answers health 204 and readiness `ready 12` on `127.0.0.1:8200`. | yes |
| AC-B1-05@v1 | Repository exclusivity: alice registers a repository. Each of these is refused with exit 65 and its code: bob through a symlinked alias (`repository-already-owned`), bob through a linked worktree (`linked-worktree`), alice a second repository (`engineer-already-owns-repository`). `repository list` shows one repository, owned by alice. | yes |
| AC-B1-06@v1 | A Profile is registered and made the repository's default; its digest is recorded. | yes |
| AC-B1-07@v1 | Ticket-originated, plan-less work: a Ticket is created and accepted, a Work Order created from it with gate evidence, claimed by `schedule run-once`, and a Work Unit admitted with no plan reference (`plan_ref` is NULL). | yes |
| AC-B1-08@v1 | The Work Order's binding is immutable: its stored Profile source digest equals the registered Profile's digest, and registering a Profile v2 later leaves its binding digest unchanged. | yes |
| AC-B1-09@v1 | Legal and forbidden transitions: accepting a ready Ticket again is `refused illegal-transition` and a stale expected revision is `refused stale-revision` (exit 65); both are listed as refusals by `ledger show`. | yes |
| AC-B1-10@v1 | Deterministic selection: of a higher-priority order without its gate evidence and a lower-priority order with it, `schedule run-once` selects the lower-priority one and lists the higher one as `ineligible … prerequisite-blocked`. | yes |
| AC-B1-11@v1 | Atomic events, claims and intents: `supervisor start` creates one intent per sandbox effect in the same decision; `supervisor execute-once` applies the repeatable one (`PASSED`). | yes |
| AC-B1-12@v1 | Crash and restart: an `execute-once` process killed after its idempotent effect applied, then a service restart, then (after the lease ends) recovery applies it under the same operation id: the sandbox shows **one** application, and the effect is `PASSED`. | yes |
| AC-B1-13@v1 | Uncertain outcome, reconciled: a queryable effect that hangs is `unknown timeout` (`RECONCILIATION_NEEDED`); `reconcile-once` looks it up, `not-applied lookup: not found`; the destination has fenced the operation id and shows no application. | yes |
| AC-B1-14@v1 | Uncertain outcome, resolved by a human: an unqueryable effect killed after applying becomes `unknown dispatch-interrupted: unqueryable effect` and halts its order. A resolution with a stale generation is `refused stale-claim`. Attesting it applied makes it `ATTESTED`, never `PASSED`. The sandbox shows one application. | yes |
| AC-B1-15@v1 | Duplicate ownership: two `execute-once` processes started together for one pending effect: one executes it; the other executes nothing — it is `idle`, or its claim is refused (`claim-held`, `dispatched-needs-recovery` or `already-settled`); one application. | yes |
| AC-B1-16@v1 | Durable, inspectable evidence: `ledger show` is identical (apart from its time line) before and after a service restart. No effect is left `UNKNOWN`, `RECONCILIATION_NEEDED` or `IN_PROGRESS`. In headless Chromium after sign-in, `/operator/ledger` shows the statuses as text (`PASSED`, `ATTESTED`) and the refused decisions. Without a session the page is refused as `/operator/center` is. | yes |
| AC-B1-18@v1 | (C-P2.9-R1 M5) Real overlap on the installed service: while a first `execute-once` process is still running and holds a dispatched idempotent effect with an active lease, a second `execute-once` executes nothing; after the first is killed and its lease ends, recovery applies the effect, one application in all. | yes |
| AC-B1-19@v1 | (C-P2.9-R1 M7) The operator's installed binary (`.local/install`, `VERSION` and binary digest) is unchanged by the run; B1 installs into `.local/b1-install`. | yes |
| AC-B1-17@v1 | Zero live-model calls, no secrets: inside the service container `claude` resolves to the shim and a canary call is logged; the service's sentinel log is empty; no password, token or session value appears in the recorded output. | yes |

## 4. Allowed paths

`scripts/b1` (new), `docs/gates/P2.9/**`, `docs/gates/B/**`, `docs/OPERATOR_GUIDE.md` (B1 note),
`DECISION_REGISTER.md` (only to point at the packet; no decision is recorded by the agent).
Product code changes only to fix a defect B1 or the review finds; each is recorded and
followed by a full re-run.

## 5. Verification

- B1 run(s): evidence under `docs/gates/B/evidence/b1/`. A failed run is kept as history, as in
  Gate A.
- The review record and its dispositions.
- The report's machine summary is computed from the B1 checks, not asserted.

## 6. Amendments

### 6.1 R-P2.9-1 (approved by the human owner, 2026-10-19)

The owner approved R-P2.9-1 as written (`r-p2.9-1-amendment-request.md`;
`.local/plans/phase-02_update2.md`: "R-P2.9-1 APPROVED as written"). Applied exactly:
- AC-B1-15 accepts the four lifecycle outcomes of a losing claim (`idle`, `claim-held`,
  `dispatched-needs-recovery`, `already-settled`), and still requires exactly one execution and
  one application.
- `scripts/b1` keeps the two processes' stdout and stderr apart.

The owner added that this alone does not make Gate B ready. Real overlap is required separately,
by remediation C-P2.9-R1.

### 6.2 R-P2.9-3 (approved by the human owner, 2026-10-20)

The owner approved R-P2.9-3 as written (`r-p2.9-3-amendment-request.md`;
`.local/plans/phase-02_update3.md`: "R-P2.9-3 APPROVED as written"). Applied exactly:
- AC-B1-03 and AC-B1-04 name revision 12 (migration 0012, C-P2.9-R1 M8) instead of 11.
- The two matching `scripts/b1` expectations change from `ready 11` to `ready 12`.

Every other criterion is unchanged. The owner accepted the bash-3.2 rewrite of the AC-B1-15
check as a script compatibility repair. Its four permitted outcomes are unchanged, and so is
the requirement of exactly one execution and one destination application. The `scripts/b1`
digest after this amendment is recorded in the Gate B report.

## 7. Stop

The decision packet is the end of Phase 2 work. Phase 3 is not begun. Anything that needs the
owner's authority is listed in the packet, not decided.
