# Amendment request A-C.R1-3 — the marker digest rule in R1, and its frozen case (for the Planner)

- Status: **APPROVED AND APPLIED.** Raised 2026-10-27 by the writing agent from Review 3, finding 2
  (`docs/gates/C/review.md`); final authorization by the Planner the same day
  (`.local/plans/phase-03_update4.md`); applied in `e679d97` (the case, R1 step (2) and the §3 row):
  digest `8e7beb24…a9c8` checked before, `97b255e2…05fe` after. The history below is kept as it was
  written.

## Why

Review 2, finding 1 (accepted provisionally by the Planner, 2026-10-27) made the attempt-marker path
compare digests, as the Planner's disposition 1 requires ("compare request digests on every
replay/conflict path"). Since `e1c56ef` the code answers a marker with the **same** digest
`decision-outcome-uncertain` and a marker with **another** digest `key-conflict`. Frozen C-C.R1 R1
step (2) still says only "an attempt marker with this key and no receipt →
`decision-outcome-uncertain`", and no frozen case covers the other-digest branch. So the contract
text trails the code, and that branch is unverified by any frozen test.

## Contract text

C-C.R1 R1, step (2):

- Now: "(2) an attempt marker with this key and no receipt → `decision-outcome-uncertain` (nothing
  applied, nothing recorded);"
- After: "(2) an attempt marker with this key and no receipt: same payload digest →
  `decision-outcome-uncertain`, other digest → `key-conflict` (either way nothing applied, nothing
  recorded);"

C-C.R1 §3, `GateCRemediationTest.hs` row: add "a marker left by another answer with the same key is
`key-conflict`".

## Exact diff

`docs/gates/C-R1/a-c.r1-3.diff` (one new case, nothing else changed):

```diff
@@ -319,6 +319,15 @@ tests =
               immutable lg "DELETE FROM lockstep_decision_attempts"
               immutable lg "TRUNCATE lockstep_decision_attempts"
               advisoryHeld lg 7301 >>= (@?= [0])
+        , testCase "a marker left by another answer with the same key is a key conflict, and nothing runs" $
+            withLedger $ \lg -> do
+              wo <- stoppedWork lg "Print the menu" "the printer jammed"
+              sql lg ("INSERT INTO lockstep_decision_attempts (idempotency_key, payload_digest, subject) VALUES ('test-remedy-key-marked', '" <> L.replicate 64 'a' <> "', '" <> T.unpack (woText wo) <> "')")
+              k <- decisionKey "marked"
+              applyDecision (lgRuntime lg) k (PutBackInLine wo 4) >>= (@?= Left "key-conflict") . outcomeOf
+              subject lg wo >>= (@?= ["halted 4"])
+              count lg "lockstep_decision_receipts" >>= (@?= 0)
+              count lg "lockstep_decision_attempts" >>= (@?= 1)
         ]
```

The marker is written directly (as the admin user) so the case does not depend on timing; a real
other-digest marker can only arise after an interruption, which the existing "lock's connection
lost" case already forces for the same-digest branch.

| File | Frozen digest (now) | Digest after the amendment |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | `8e7beb24a0ef48b86eec4a8368d2f180cf2be105ed63c074a45c88f55e01a9c8` | `97b255e2f65d0d7abfbd4a73842baf6b95ea81a902f2e675975b35b4510605fe` |

Not compiled or run (no build or test started under the current stop instruction). Expected: it
passes at `e1c56ef` and would have failed at `e49b68e` (which answered
`decision-outcome-uncertain`); both to be shown at the next qualification.

## What the Planner decides

1. Approve the text and the diff, to be applied with A-C.R1-1 and A-C.R1-2 under one re-freeze and
   one qualification; or
2. keep R1 (2) as written, in which case the code must go back to `decision-outcome-uncertain` for
   every marker (and Review 2 finding 1 is withdrawn); or
3. another disposition.
