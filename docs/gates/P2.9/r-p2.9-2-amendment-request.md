# R-P2.9-2 — protected-test amendment request (C-P2.7 `ReconciliationTest`)

- Prepared by: the writing agent (Implementer), 2026-10-19. Status: `REQUESTED`. Not applied.
- File: `test/integration/Lockstep/ReconciliationTest.hs`, frozen at `1730ebd`, SHA-256
  `51e5edef534d007f26c1fd68af12d7703aacba6845b1ac72cf53587b2486aac1`.
- Cause: remediation items 2 (activation fencing) and 4 (abandonment halts its subject), which
  you authorized in `.local/plans/phase-02_update2.md`. Three frozen cases assert exactly the
  behaviour those items remove:
  1. **"authoritative not found … retried"** (lines 161–179): after a halt, requeue and restart,
     the *earlier activation's* intent executes. Under fencing it must not.
  2. **"human: a retry …"** (lines 271–288): the same, after an acknowledged human retry.
  3. **"abandoned, then applied"** (lines 307–317): it expects the order to be halted by the
     *late-application* conflict, with no abandonment record. Under DG-04 D-4.6 the abandonment
     itself halts the order and is recorded.

No other frozen test conflicts. I checked every use of requeue, restart and abandon in the
frozen suites: the P2.5 requeue case runs no intent; the P2.5 and P2.6 abandon cases assert
nothing the change affects.

## Proposed diff

The scenarios are kept; each case gains the refusal and the explicit human step that the new
rules require. Cases 1 and 2 still prove the retry keeps its operation id (DG-04 requirement 1)
and still require exactly one application.

```diff
@@ imports (Lockstep.Application.Ledger)
   , abandonIntent
+  , carryIntent
   , claimIntent
@@ case 1
-    , testCase "authoritative not found: confirmed not applied, then retried with the same operation id" $
+    , testCase "authoritative not found: confirmed not applied; after a restart it runs again only once a Human carries it, same operation id" $
@@
           restartOrder lg wo
+          refused "activation-superseded" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opC ops))
+          carried <- ok "carry" (carryIntent (lgRuntime lg) (opC ops))
+          intentGeneration carried @?= 2
           retried <- ok "execute" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opC ops))
@@ case 2
-    , testCase "human: a retry needs the duplication risk acknowledged; then the same operation id runs again" $
+    , testCase "human: a retry needs the duplication risk acknowledged; after a restart and a Human carry, the same operation id runs again" $
@@
           restartOrder lg wo
+          refused "activation-superseded" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opD ops))
+          carried <- ok "carry" (carryIntent (lgRuntime lg) (opD ops))
+          intentGeneration carried @?= 1
           result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opD ops))
@@ case 3
-    , testCase "abandoned, then applied: a late-application conflict halts the order" $
+    , testCase "abandoned, then applied: the abandonment halts the order and is recorded; the late application is still recorded" $
@@
           refused "already-settled" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = abandon} (opA ops))
-          haltedFor lg wo ("late-application operation=" <> opText (opA ops))
+          haltedFor lg wo ("abandoned operation=" <> opText (opA ops))
           ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
-            >>= (@?= [StoredResolution 1 "late-observation" "late-application applied result=\"ok\"" False])
+            >>= (@?= [StoredResolution 1 "human-abandon" "abandoned reason=\"operator stop\"" False, StoredResolution 1 "late-observation" "late-application applied result=\"ok\"" False])
```

Unchanged:
- every other case;
- every application count;
- the fencing generations: a carry rebinds the activation, not the fencing generation, so the
  existing `intentGeneration after` and `intentDispatches after` assertions stand.

## Decision requested

Approve R-P2.9-2 as written, or choose another design for the carry-forward of an authorized
retry. Options:
- **(a, recommended)** an explicit Human `carryIntent`, as above;
- **(b)** no carry: a retry after a halt always needs a new intent with a new operation id.
  That contradicts DG-04 requirement 1, "retries must retain the original operation ID".

If approved, I will implement C-P2.9-R1, freeze its new tests, apply this diff and re-freeze,
then run all the verification and B1 run 2, obtain the second review, and write the Gate B report
and packet.
