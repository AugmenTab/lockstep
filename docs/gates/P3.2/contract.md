# Contract — P3.2 System status and lifecycle

- Contract ID: `C-P3.2@v1`
- Status: **FROZEN** (2026-10-26; §5)
- Authority: Phase 3 handoff P3.2; PRD v0.3 FR-UX-02, FR-UX-03; Plan v0.3 §4 P3.2 and DG-16
  ("authenticated, versioned, allowlisted serialized host operations with replay/parameter
  protection and durable outcomes"); the approved P3.1 architecture (DG-15, C-P3.1).
- Writer: the single writing agent (Implementer, manual).
- Scope: the control pane's system view and Start / Stop / Restart. Install, upgrade, migrate,
  backup and restore are P3.3 and are **not** here.

## 1. What P3.2 delivers

1. A system view in the control pane that shows, in plain words and from observed facts: the
   installed version, whether the service runs and answers, the database server, readiness and
   schema compatibility, Docker (the one runtime dependency) and Git, and the last start or stop
   error.
2. Buttons that start, stop and restart the service and start or stop the database server. Each
   button sends one **lifecycle request** naming the operation and the state the page showed;
   the helper re-checks that state before acting and refuses if it changed.
3. At most one lifecycle operation at a time, enforced by the pane (a second request while one is
   pending is refused) and by the helper (one operation at a time; each checks its expected
   state).

## 2. Decisions

| # | Decision |
|---|---|
| M1 | **A separate request kind.** C-P3.1's status channel (`lockstep-control-request 1`, allowlist `status`) and its frozen tests are unchanged. Lifecycle requests are a second, distinct kind, `lockstep-lifecycle-request 1`, written as `requests/<id>.lreq`, signed with the same channel key, with their own allowlist and a mandatory expected state. Results use the existing result format. The two kinds stay separate because one only reads and the other changes the computer. |
| M2 | **Allowlist v1.** `service-start` (expect `not-running`), `service-stop` (expect `running`), `service-restart` (expect `running`), `database-start` (expect `not-running`; operator only), `database-stop` (expect `service-not-running`: the service must be stopped first; operator only). Nothing else is accepted. No argument comes from the browser: the operation name and the expected state are the whole request. |
| M3 | **Fixed commands.** `service-start`: `scripts/service [--instance N] start --port P` (or `restart --port P` when a stopped container exists); `service-stop`: `scripts/service [--instance N] stop`; `service-restart`: `scripts/service [--instance N] restart --port P`; `database-start`: `scripts/db up`; `database-stop`: `scripts/db down`. `P` is fixed when the helper starts (`--service-port`, from `LOCKSTEP_SERVICE_PORT` or 8000). |
| M4 | **Checks before and after.** Before: the expected state must hold; `service-start` and `service-restart` also need a compatible installation (`db status` says `readiness ready`), otherwise `refused not-compatible` (upgrades are P3.3). After: the helper observes the result again and reports `ok` only if the service answers its health check (start, restart) or is gone (stop), or the database is ready (start) or stopped (stop); otherwise `failed`, with the last error as `detail`. |
| M5 | **Refusal codes** (in addition to C-P3.1 §4): `state-changed`, `not-compatible`, `not-managed`, `busy`. |
| M6 | **Pane API.** `POST /api/lifecycle` (exact Host and Origin, session; body `<op> <expect>`) → `202 {"id":…}`; an unknown operation or an expectation that does not fit it → `400`; a lifecycle request still pending → `409`. Results are read with the existing `GET /api/requests/<id>`. |
| M7 | **Status fields added** (the `status` operation, protocol unchanged): `service.health` (answers / no-answer / unknown), `service.port`, `service.exit-code`, `docker.server` (version or unknown), `git.present`. |

## 3. Lifecycle request format

```
lockstep-lifecycle-request 1
id <32 lower-case hex>
issued <unix seconds>
op <operation>
expect <expected state>
mac <64 lower-case hex>
```

The same checks as C-P3.1 §4 apply (regular file owned by the user, private mode, at most 1024
bytes, exact lines, MAC, unseen id, `issued` within 120 s past / 10 s future), then the M2
allowlist and the M4 checks. A request id is seen once across both kinds.

## 4. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Foundation/LifecycleProtocolTest.hs` | unit | encoding vectors (`openssl`), strict parsing, the allowlist and expected states, every malformed form, the status kind still refusing lifecycle names |
| `test/integration/Lockstep/LifecycleHelperTest.hs` | integration, real helper, `docker` and `curl` stubbed with a state machine | each operation succeeds and is observed afterwards; expected state wrong → `state-changed` and nothing runs; incompatible → `not-compatible`; `database-stop` while the service runs → refused; instance mode database operations → `not-managed`; a failed start reports `failed` with its error; a start that never answers is `failed`, not `ok`; two lifecycle requests at once run one after the other and the second is refused as `state-changed`; forged, replayed, stale and unknown requests refused; timeout and interruption; the status kind is unaffected |
| `test/integration/Lockstep/LifecyclePaneTest.hs` | integration, real pane | `/api/lifecycle` guard and session; unknown operation and wrong expectation `400`; a second request while one is pending `409`; the request file is a signed lifecycle request; the status channel still refuses lifecycle names |
| `test/integration/Lockstep/LifecycleBrowserTest.hs` | integration, headless Chromium | the system view shows the observed state in words; Stop, Start and Restart change it; a button is unavailable while an operation runs; a double click makes one operation |
| `scripts/lib/check-lifecycle` + `scripts/lib/lifecycle-smoke-browser` | host, real Docker, instance `p32c` | real stop, start and restart of the instance service from the browser; the status page reflects each; the operator's service, database and control pane are untouched |
| `test/integration/Lockstep/Support/Lifecycle.hs` | test support | throwaway checkout with stateful `docker` and `curl` stubs |

Page wording the tests rely on: buttons `#service-start`, `#service-stop`, `#service-restart`
(and `#database-start`, `#database-stop`); after a successful operation "Done: the service was
stopped." / "started." / "restarted."; the service row reads `Running` or `Not running`; the page
names Docker. One lifecycle operation at a time: a button is disabled while one runs. The helper
takes `--service-port N` (the launcher passes `LOCKSTEP_SERVICE_PORT`, default 8000).

## 5. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the lifecycle operations were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/LifecycleProtocolTest.hs` | `a252d257545f12b1974a2cfe0576c54e827deae2f009611972a87a25d959f510` |
| `test/integration/Lockstep/LifecycleHelperTest.hs` | `8a3925f8879edf89b023a25e890c583e8060df7275b88ffc59c010f11d921b99` |
| `test/integration/Lockstep/LifecyclePaneTest.hs` | `a1a65b1a80f7f84547c6ac50018f6ee6b37ea2e782af1eae960e4120a0a800fb` |
| `test/integration/Lockstep/LifecycleBrowserTest.hs` | `04134f36a1b8ae18056d85bf9b47d9891a30ce82fac83ecc5c3f06ba2c094956` |
| `test/integration/Lockstep/Support/Lifecycle.hs` | `cc6893eef464e38f88179dfbfb209b257fea896eb2cbd42c56eabad40bc38ebe` |
| `scripts/lib/check-lifecycle` | `e161a093f332c394f393e5986332687e4a356d4e2f3a1ba5cfc9a2dad4508f3a` |
| `scripts/lib/lifecycle-smoke-browser` | `4ac72f1b723d0b0e24132a244a5a9fd742b0589306150c1998f6fcb0f58602cc` |
| `test/unit/Main.hs` (runner, additive since C-P3.1) | `5fb3a8f80a6dec776bab985ed111e645afbde00be01613554ad10834578a8750` |
| `test/integration/Main.hs` (runner, additive since C-P3.1) | `23b5ceeb8e1814d5496bcea20d51ac04142fc421c0fa740a7843e4203d7ca4e0` |

The C-P3.1 frozen tests are untouched; the runner changes add lines only.

Pre-freeze verification (logs in this folder):

- Unit baseline against type-only stubs (`prefreeze-unit-baseline.log`): 9 of 724 fail, all new;
  three new cases pass against the stubs (the status channel refusing lifecycle names, which is
  the C-P3.1 parser; the HMAC vector, which uses the C-P3.1 `hmacHex`; and a refusal case).
- As in C-P3.1, the lifecycle codec was then implemented before the freeze, because the
  integration fixtures encode requests through it: all 12 unit cases pass. The HMAC vector had
  been computed with `openssl` first.
- Integration fixtures against the C-P3.1 helper and pane, after adding only the helper's
  `--service-port` argument (`prefreeze-integration-baseline.log`,
  `prefreeze-helper-scaffold.log`): 21 of 23 fail, each on its behaviour (no lifecycle result,
  404 for `/api/lifecycle`, no Stop button). Two pass: the status channel refusing a lifecycle
  name (C-P3.1 behaviour) and lifecycle content in a status-kind file refused as malformed (the
  C-P3.1 parser).
- Host check against the current launcher (`prefreeze-check-lifecycle.log`): ran to the end and
  cleaned up; it fails at the Stop button. One fixture defect was fixed before the freeze: the
  smoke browser threw away earlier observations when the driver failed later.
