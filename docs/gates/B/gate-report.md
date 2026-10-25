# Gate B report — Phase 2: independent work identity, policy and the durable effect protocol

- Revision: **r2**, 2026-10-25. Prepared by the writing agent (Implementer). **Not a decision**:
  Gate B is decided only by the human owner (§7).
- **Tested commit: `6ba66f59f46c04f32982a5e4b96f1ac13017853c`.** The B1 run, the fresh-clone check
  inside it, the `lockstep open` check and the Linux clean-clone check all ran on it.
- Machine summary: **`PASSED`**. Every required B1 criterion passed in run 4 (19/19). That
  summary is evidence, not acceptance.
- **r1 is superseded**, for two reasons:
  - The owner approved a change to `scripts/service` and `scripts/lockstep` after r1 (§2.2).
  - r1 miscounted the B1 criteria as 20. There are 19 (AC-B1-01 to AC-B1-19): run 3 was
    19/19, not "20/20", and run 2 was 16/19, not "17/20".
- Phase 3 has not begun.

## 1. B1 criteria (run 4, `docs/gates/B/evidence/b1-run4/`)

Run `20261025T162130Z`. Database `lockstep_b1_20261025t162130z`, kept for inspection; the
installed service ran on `127.0.0.1:8200`.

| Criterion | Result | Evidence (run 4) |
|---|---|---|
| AC-B1-01 fresh clone passes `scripts/check --integration` | PASSED | `check-fresh-clone.log`: all six steps; 678/678 unit, 181/181 integration |
| AC-B1-02 release binary from a clean checkout | PASSED | `VERSION`: `6ba66f5…`, `dirty false`, binary `02ad7568…` (identical to run 3: only shell scripts changed); installed into `.local/b1-install` |
| AC-B1-03 fresh database at revision 12 (R-P2.9-3) | PASSED | `b1.log` §B1-03 |
| AC-B1-04 health 204, readiness `ready 12` (R-P2.9-3) | PASSED | `b1.log` §B1-04 |
| AC-B1-05 repository exclusivity | PASSED | three refusals, each exit 65 with its code; one repository listed |
| AC-B1-06 Profile registered as the default | PASSED | digest `96029c2a…` |
| AC-B1-07 Ticket-originated, plan-less work | PASSED | `plan_ref` NULL |
| AC-B1-08 immutable binding | PASSED | the binding is unchanged after Profile v2 |
| AC-B1-09 legal and forbidden transitions | PASSED | `illegal-transition` and `stale-revision`, both listed |
| AC-B1-10 deterministic selection | PASSED | the higher-priority order is `ineligible … prerequisite-blocked` |
| AC-B1-11 atomic events, claims and intents | PASSED | repeatable effect `PASSED` |
| AC-B1-12 crash, restart, recovery | PASSED | one sandbox application, `PASSED` |
| AC-B1-13 uncertain outcome, reconciled | PASSED | `not-applied lookup: not found`; the destination fenced the id |
| AC-B1-14 uncertain outcome, human-resolved | PASSED | `stale-claim` refused; `ATTESTED`, never `PASSED`; applied once |
| AC-B1-15 duplicate ownership (R-P2.9-1) | PASSED | a real refusal again: one process `executed … applied`, the other `refused dispatched-needs-recovery`; one application |
| AC-B1-18 real overlap on the installed service (C-P2.9-R1 M5) | PASSED | while the first process was still running and held the dispatched effect (lease active), the second executed nothing; after the kill and the lease end, one application in all |
| AC-B1-16 durable, inspectable evidence; real browser | PASSED | `ledger-before/after-restart.txt` identical apart from the time; headless Chromium `ledger-page-text.txt` shows `PASSED`, `ATTESTED` and the refusals; refused without a session |
| AC-B1-17 zero live-model calls, no secrets | PASSED | the shim resolves; canary exit 97; sentinel log empty; no token, password or session value in the output |
| AC-B1-19 operator's binary untouched (C-P2.9-R1 M7) | PASSED | `.local/install` `VERSION` and binary digest unchanged |

`SHA256SUMS` (run 4):

| File | SHA-256 |
|---|---|
| `b1.log` | `e1f10677a1f67f60de67b1240388febcb297d825c5b524d72a926c384595ea9d` |
| `check-fresh-clone.log` | `2777e6ec313c9896183144ef9ddfa3b9d9c5be40e8a3e79ec961ba89d1b61300` |
| `ledger-after-restart.txt` | `a2b030b6f5ee2424c91b32f6acfcef9c65798e38a73b8d0f03279016ced0dfff` |
| `ledger-before-restart.txt` | `5b089a3420b39783bb7d8db592ac85a005de7ab49b82f602230c17294ec9621d` |
| `ledger-page-text.txt` | `71fe1c3d8d437fdd2c7e99605bbc30a061c0b0e027782530d9f38f5206ffeb38` |
| `service.log` | `dd7d815e30a9c01a0c0e3809362ad9e2b43380980fb4c340d704d1ad3a4d058f` |
| `VERSION` | `4b5f8a262a0bccb175123dd1334d2512e81f9a804f5fa30bb47cdfb68adc8e3a` |

### 1.1 Earlier runs (kept unchanged as history)

| Run | Commit | Result | Why it did not stand |
|---|---|---|---|
| 1 (`b1-run1/`) | `1e59942` | 16/17 | AC-B1-15 named too few refusal codes (R-P2.9-1). The first independent review then found 6 MEDIUM, which led to remediation C-P2.9-R1 (and AC-B1-18/19). |
| 2 (`b1-run2/`) | `de3ebc5` | 16/19 (r1 said "17/20") | AC-B1-03/04 named revision 11; migration 0012 makes it 12 (R-P2.9-3). AC-B1-15 hit a bash-3.2 syntax error in its own check, since repaired with semantics unchanged; the owner accepted the repair. |
| 3 (`b1-run3/`) | `7ecb5ac` | 19/19 (r1 said "20/20") | Passed; superseded only because the owner-approved `--instance` change (§2.2) came after it. |
| 4 (`b1-run4/`) | `6ba66f5` | **19/19** | — |

## 2. Verification of the tested commit

| Check | Result | Evidence |
|---|---|---|
| `scripts/check --integration`, fresh clone (inside B1) | all six steps PASSED; 678/678 unit, 181/181 integration | `b1-run4/check-fresh-clone.log` |
| Linux clean clone (case-sensitive filesystem), in the dev container | format, lint, build, unit and integration PASSED; 678/678, 181/181; the Kernel boundary and the purity scan are clean | `docs/gates/P2.9/r1-evidence/linux-clone-6ba66f5.log` (transcribed from the run's output) |
| `scripts/lib/check-open` (C-OPEN, frozen) | 22/22 PASS, including real headless Chromium reaching `/operator` | `docs/gates/B/evidence/check-open-6ba66f5.txt` |
| `--instance` and the port check, by hand | `--instance b1 status` and `db status` (`ready 12`) work; `service`, `B1` refused 64; an unknown instance refused 66; `scripts/service start` on a port already answering refused 75 and started nothing; the operator's `scripts/service status` unchanged (`6c2851d`, not running) | this session; no environment variables set |

The integration step covers:
- real PostgreSQL 17;
- real crashes;
- two real worker processes that overlap (`two worker processes really overlap…`);
- a headless-Chromium browser test of the served forms (`served forms work in a real browser…`);
- the non-loopback refusal;
- backup and restore.

### 2.1 Frozen and amended artifacts (all digests re-verified 2026-10-25)

| Artifact | SHA-256 | Record |
|---|---|---|
| `test/unit/Lockstep/Kernel/RemediationTest.hs` | `ed16cbf34d6be27dadab143f416dff1f3ed5115497ba1404a1fbb5f2dd18f271` | C-P2.9-R1 §4.1 |
| `test/integration/Lockstep/RemediationTest.hs` | `4e3918ac06e2ba055e048b93fa852828522ace07ad52496ae68ae50694cdd477` | §4.1 |
| `test/integration/Lockstep/ReconciliationTest.hs` (R-P2.9-2) | `58701dc0225ae812a14d6d86588ca465071cd55f5b2511bc4dd93b70007d0a99` | §4.1, C-P2.7 §10.1 |
| `test/unit/Lockstep/Kernel/RemediationReviewTest.hs` | `c041482e10e49fb336ffd3c116522e878fafd182cad0f159a37a1c6a60563230` | §4.4 |
| `test/integration/Lockstep/RemediationReviewTest.hs` | `655bd8865c9a38eac5962f058edfce07ed0e2506b0e3f7b596b19681bd340354` | §4.4 (first record withdrawn before any run, disclosed in §4.3) |
| `test/unit/Lockstep/Kernel/RemediationThirdReviewTest.hs` (R-P2.9-4) | `daf50a6d9b7bc8c18e5d1d112881f00f448dea23c6e38180c09402b06244bf1f` | §4.6 |
| `test/integration/Lockstep/RemediationThirdReviewTest.hs` | `e8bda1a1cc54ae8a1712fd6292f412d7443ff4a89aad8fb55ee125c3bc41026c` | §4.5 |
| `test/unit/Lockstep/Foundation/CliFinalReviewTest.hs` | `e9b817a03ac728ebae432a78fa1bbbd10881dd650199e240c61b35877fcf708f` | §4.7 |
| `test/integration/Lockstep/RemediationFinalReviewTest.hs` | `b11bd9009a0efad963c99f9abc94e7e1162c156a2ab75dd2da4c4ed6c4bd3302` | §4.7 |
| `scripts/b1` (R-P2.9-1, R-P2.9-3 and the bash-3.2 repair) | `07250cbe61cf42d861033ee8d2b6fb85cbf798918ce24b27b0b85d49aa3842a5` | C-P2.9 §6 |
| `scripts/service` (owner-approved `--instance` diff) | `464795be82be742f4a58d5f94db11aa4c5cc9327c6cb64549b05eda12fddaf2e` | §2.2; was `40f9d2fa…` (C-P2.9-R1 §4.7 F4) |
| `scripts/lockstep` (same diff) | `84367c9b62218b91197e4e3eb46b9138833932a9f13c1f9b198f73513ba9ae53` | §2.2 |
| B1 release binary (`6ba66f5`) | `02ad756814a22d043b80cd9c80ec0c92b04fdc1e7b736a1a216f2e5bc57c8aeb` | `b1-run4/VERSION` |

### 2.2 The change after r1 (`6ba66f5`, owner-approved diff)

Selecting B1's install took three environment variables and a remembered port, so the web review
was impractical. The owner approved this exact diff on 2026-10-25:
- `scripts/service --instance NAME …` and `scripts/lockstep --instance NAME …` select container
  `lockstep-NAME`, install `.local/NAME-install` and config `.local/config/lockstep-NAME.json`.
  The name is lower-case letters, digits and `-`; `service` is refused, because it would control
  the operator's own container. A missing config is refused 66. The existing install-directory
  checks still apply.
- `scripts/service start` refuses a port on which something already answers (75). Before, the
  start could report success against another service on that port.
- One line in `docs/OPERATOR_GUIDE.md` §4.

No Haskell source, test or frozen test changed; the binary digest is identical. Review: no
independent review was run on this shell change; it is small, and every check above was rerun.

## 3. Sub-phase status

| Item | Status | At |
|---|---|---|
| P2.1 repository identity and exclusivity | VERIFIED — awaiting your acceptance | `2eb97c5` |
| P2.2 Work Units and plan-less work | VERIFIED — awaiting your acceptance | `ed9e160` |
| `lockstep open` | VERIFIED (22/22 again at `6ba66f5`); your default-browser check is pending | `0b14997` |
| P2.3 Profiles | VERIFIED — awaiting your acceptance (R-P2.3-1) | `c9100c0` |
| P2.4 scheduler | VERIFIED — awaiting your acceptance | `cc11ea0` |
| P2.5 durable ledger and effect intents | VERIFIED — awaiting your acceptance (R-P2.5-1) | `837ddbc` |
| P2.6 executor and recovery | VERIFIED — awaiting your acceptance | `ef2c429` |
| P2.7 reconciliation | VERIFIED — awaiting your acceptance (R-P2.9-2 amends its frozen test) | `2297cfc` |
| P2.8 ledger projection and CLI | VERIFIED — awaiting your acceptance; its real-browser page check ran as AC-B1-16, PASSED | `28226d9` |
| P2.9 B1 and the C-P2.9-R1 remediation | VERIFIED — awaiting your acceptance | `6ba66f5` |

The P2.5–P2.8 behaviour changed after those sub-phases were verified, through C-P2.9-R1
(activation fencing, key lifetime, carries, abandonment). The tested commit above is the one
that matters for Gate B.

## 4. Remediation and independent reviews

All reviews were made by read-only reviewer agents of the same model family as the writer.
**None is a human review.** Dispositions: `docs/gates/B/review.md` (first) and
`docs/gates/B/review-remediation.md` (second to fifth).

| Review | Scope | HIGH | MEDIUM | Outcome |
|---|---|---|---|---|
| 1 | Phase 2 at `1e59942` | 0 | 6 | remediation C-P2.9-R1 M1–M8 (`27a9765`) |
| 2 | C-P2.9-R1 | **2** | 2 | addendum N1–N8 (`8fce278`): the class-B key check on every dispatch; the checked carry |
| 3 | N1–N8 | 0 | 2 | P1–P4 (`53ee0d5`): one live intent per effect key; the acknowledgment in every carryable state; retries refused past the key guarantee |
| 4 | P1–P4 | 0 | 1 | F1–F4 (`2a8e414`): a dispatched abandoned intent keeps its key until the abandonment is acknowledged |
| 5 (confirmation) | F1–F4 | **0** | **0** | 2 LOW: one fixed, one a recorded limitation (§5) |

No HIGH or MEDIUM finding remains open. The new tests of each round were frozen; from the
third round on, they were also run before the fix. The lapses are disclosed in C-P2.9-R1 §4.3
and §4.6, and the criteria miscount at the top of this report.

Your requirements for the carry (R-P2.9-2) and how they are met:
1. An earlier activation's intent is refused `activation-superseded` and skipped until a Human
   carries it.
2. A carry runs as one transaction under the order lock and then the intent lock. It checks
   the principal, the activation, the expected activations (`stale-carry`), the state,
   ownership, the key, the acknowledgment and same-key conflicts (`carry-conflict`).
3. Only the activation changes. The operation id, parameters, budget, dispatch count and
   history stay as they were.
4. An unknown intent is `outcome-unknown` until a Human resolves it. A retry needs the
   acknowledgment, and a carry needs it after any attestation. Class-B: no claim, dispatch,
   carry or retry past the key guarantee.
5. A `human-carry` row records the principal, the source and target generations and the
   acknowledgment. An Agent is `agent-assertion`; a Supervisor or Scheduler is
   `not-authorized`.
6. Regressions: in the five frozen remediation files and the frozen C-P2.7 suite.

## 5. Known issues and limitations

1. **Authority by command** (review 1, finding 14): the CLI and web commands carry their
   principal implicitly, with no authenticated principal. This is by design for Phase 2; it is
   carried to Phase 3.
2. **One live intent per effect key per Work Order** (review 4, LOW 2). A key belongs to one
   logical effect on an order. A later intent with the same key never runs beside a live one,
   and a settled-applied one blocks it for good. Alternative: refuse at admission (decision 3
   in the packet).
3. **An unacknowledged abandonment of a sent effect cannot be acknowledged later** (review 5,
   LOW 1). It fails closed: the key stays held on that order, and the work moves to a new order.
   A Human-only `acknowledge-abandon` command is offered (decision 4).
4. **Class-B after an attested "not applied" with an expired key**: the intent goes back to
   unknown at dispatch. This is safe but not useful. The guidance is "attest that it applied,
   or abandon with the acknowledgment".
5. **Migration 0012 gives pre-migration intents activation 1** (review 2, finding 9). Such an
   intent is fenced and needs a carry. None exists outside test databases.
6. **Overlap evidence on the installed service**: in runs 3 and 4, AC-B1-15 showed a real
   refusal under contention, and AC-B1-18 showed the second process executing nothing while the
   first held the in-flight effect. The refusal under overlap is also proved by the integration
   regression `two worker processes really overlap…`, with real processes and a real database.
7. **`scripts/service`**: the symlink check applies to the last path part only. This is
   acceptable for a local operator script.
8. **Your operator installation.** `.local/install` holds a **rebuild** of the Gate A commit
   `6c2851d` (binary `eea16b63…`); it may not be byte-identical to the original install.
   - Your `lockstep-service` is stopped. Your operator database is untouched, at schema 5.
   - Running Phase 2 on it needs a backed-up `db migrate` to 12 and an install of the accepted
     commit. That is your decision, and nothing here has done it.
   - B1 databases `lockstep_b1_*` from runs 1–4 are kept on your PostgreSQL server for
     inspection.
9. Queryable recoveries wait for `supervisor reconcile-once`; there is no daemon, by design.
10. **Launching is still multi-step for a first-time operator**: upgrading an install is a backup,
    a migrate and an install by hand. `--instance` removes the environment variables but not that.

## 6. What changed for operators

The operator guide (§4 and §6) covers:
- `--instance NAME` for a qualification install, e.g. `scripts/lockstep --instance b1 open`;
- carries: `effects carry OP --from-activation S --to-activation T
  [--acknowledge-duplication-risk]`;
- abandonment, and its acknowledgment;
- `effect-key-in-use` and how to resolve it;
- the class-B key rules.

## 7. Decision (owner only)

Gate B is not recorded as accepted. The decisions are listed in
`docs/gates/B/decision-packet.md`.
