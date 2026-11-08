# Amendment request A-C.R1-4 — frozen cases that assert removal of a published folder (for the Planner)

- Status: **APPROVED AND APPLIED** (final Planner authorization, 2026-10-27; original digests
  checked, each diff applied to its intended test path, results equal the authorized digests; C-C.R1
  §1, §3, §3b, §3c and §4 amended). The history below is kept as it was written.
- Raised 2026-10-27 by the writing agent under the Planner's
  final engineering authorization for Review 6 (`.local/plans/phase-03_update5.md`, "Contracts and
  tests": "If an existing frozen test conflicts with this safer requirement, prepare its exact
  amendment diff and before/after digests for one consolidated authorization").
- The three frozen files below are **unchanged** in the repository. Until this is authorized, the
  three cases fail at the candidate, each because the folder is now kept (C-C.R1 R6-1).

## Why

C-C.R1 R6-1 (§3e) supersedes the rule that a failed attempt removes the folder it made: once
published, a folder is never removed. Three frozen cases assert the old rule:

| File | Case | What it asserts now | Conflict |
|---|---|---|---|
| `GateCRemediationTest.hs` (C-C.R1 §3, R5) | a failure at the Engineer, the registration or the project write leaves nothing behind | the projects folder is empty after the failure | the made folder `garden` is kept |
| `GateCRemediationAddendumTest.hs` (§3b, R13) | a failed attempt still removes the folder it made when the project does not record it | only `notes` is left | `garden` is kept beside it |
| `GateCRemediationFolderRaceTest.hs` (§3c, R13b) | an attempt waits with a folder another attempt made and then removed | the first attempt's folder is gone after its interruption, which is what makes the second attempt's folder missing | the first attempt keeps it, so the case's own setup no longer happens |

Every other assertion in these cases still holds and is kept: no Engineer, no registration, no
decision rows and the project unchanged after a database failure; *Try again* connects; and R13b
(no project is recorded as connected to a missing folder). For the third case the amendment keeps
R13b's coverage by having the test itself remove the kept folder while the second attempt waits
(standing for someone else removing it), instead of relying on Lockstep's removal.

## Exact diffs

Applied to the paths under `test/integration/Lockstep/` (the patch headers name the `.local`
working copies the digests were taken from).

`docs/gates/C-R1/a-c.r1-4-remediation.diff`:

```diff
@@ -374,7 +374,7 @@ tests =
               counted sc "lockstep_engineers" >>= (@?= 1)
               counted sc "lockstep_repositories" >>= (@?= 1)
               listDirectory (scRoot sc) >>= (@?= ["garden"])
-        , testCase "a failure at the Engineer, the registration or the project write leaves nothing behind" $
+        , testCase "a failure at the Engineer, the registration or the project write leaves no Engineer, registration or project change, and keeps the folder it made" $
             traverse_
               ( \(table, event) ->
                   withScenario $ \sc -> do
@@ -383,7 +383,7 @@ tests =
                     execute sc ("CREATE TRIGGER remedy_fail BEFORE " <> event <> " ON " <> table <> " FOR EACH ROW EXECUTE FUNCTION remedy_fail()")
                     r <- connectProject (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
                     assertBool (table <> ": not a failure: " <> show (fmap (fmap projectId) r)) (isLeft r)
-                    listDirectory (scRoot sc) >>= (@?= [])
+                    listDirectory (scRoot sc) >>= (@?= ["garden"])
                     traverse (counted sc) ["lockstep_engineers", "lockstep_repositories", "lockstep_identity_decisions"] >>= (@?= [0, 0, 0])
                     after <- ready (findProject (scRuntime sc) (projectId view))
                     fmap (\v -> (projectSetup v, projectRevision v, projectEngineer v)) after @?= Just (Organized, 1, Nothing)
```

`docs/gates/C-R1/a-c.r1-4-addendum.diff`:

```diff
@@ -116,7 +116,7 @@ tests =
                 folder = scRoot sc <> "/garden"
               recorded sc view >>= (@?= Just (Connected, Just (T.pack folder)))
               listDirectory (scRoot sc) >>= (@?= ["garden", "notes"]) . L.sort
-        , testCase "a failed attempt still removes the folder it made when the project does not record it" $
+        , testCase "a failed attempt keeps the folder it made and records nothing (R6-1)" $
             withScenario $ \sc -> do
               createDirectory (scRoot sc <> "/notes")
               view <- made sc "garden" "Garden" DecideLater
@@ -125,7 +125,7 @@ tests =
               result <- connectProjectWith (ProjectFaults pure) (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
               assertBool ("not a failure: " <> show (fmap (fmap projectId) result)) (either (const True) (const False) result)
               recorded sc view >>= (@?= Just (Organized, Nothing))
-              listDirectory (scRoot sc) >>= (@?= ["notes"])
+              listDirectory (scRoot sc) >>= (@?= ["garden", "notes"]) . L.sort
         ]
```

`docs/gates/C-R1/a-c.r1-4-folder-race.diff`:

```diff
@@ -15,7 +15,7 @@ import Control.Exception (SomeException, throwIO, try)
-import System.Directory (createDirectory, doesDirectoryExist)
+import System.Directory (createDirectory, doesDirectoryExist, removeDirectoryRecursive)
@@ -114,7 +114,7 @@ tests =
-    , testCase "an attempt waits with a folder another attempt made and then removed; it is not recorded as connected to a missing folder" $
+    , testCase "an attempt waits with a folder another attempt made, kept, and someone then removed; it is not recorded as connected to a missing folder" $
@@ -130,8 +130,10 @@ tests =
-          gone <- not <$> doesDirectoryExist (scRoot sc <> "/garden")
-          assertBool "the first attempt's own folder was not removed" gone
+          kept <- doesDirectoryExist (scRoot sc <> "/garden/.git")
+          assertBool "the first attempt's published folder was removed" kept
+          -- C-C.R1 R6-1: Lockstep keeps it; someone else removes it while the second attempt waits.
+          removeDirectoryRecursive (scRoot sc <> "/garden")
           putMVar resume ()
```

(The third block is condensed here; the `.diff` file holds the full context lines.)

| File | Frozen digest (now) | Digest after the amendment |
|---|---|---|
| `test/integration/Lockstep/GateCRemediationTest.hs` | `97b255e2f65d0d7abfbd4a73842baf6b95ea81a902f2e675975b35b4510605fe` | `7001908ecc928fe3aa55468907911e86c67e24cf40e279cc5c974590cef4096c` |
| `test/integration/Lockstep/GateCRemediationAddendumTest.hs` | `16235a713b695f91f196a42379ad08c5aff5ecb54cbafc52ea0c3dd4493451ec` | `36c0e5d8171c8d8f359ee7ff168b97d1b45725cd815695733bec48bb9eb758fd` |
| `test/integration/Lockstep/GateCRemediationFolderRaceTest.hs` | `b5872215d9ff11c12a03eac615386ee9bfdf3aee0736e8f1450a3cf87e6029bb` | `3306dc0cef4c7b6709f356164a8d279fd8b055569620628253ee8e1e05404477` |

Contract text, with the amendment: C-C.R1 §1 item 2 "a failed attempt leaves no Engineer, repository
registration or new folder behind" → "… no Engineer or repository registration behind, and keeps
any folder it published (R6-1)"; the §3 R5 row "a failure at the Engineer, the registration or the
project write → no Engineer, no registration, no new folder, project unchanged" → "… the new
folder kept"; the §3b R13 row "a really failed attempt still removes the folder it made" → "a
really failed attempt keeps the folder it made"; the §3c R13b row "a folder the other attempt made
and then removed" → "made, kept, and someone then removed".

## Trial

At the candidate `fd5bb90`: without the amendment, the C-C.R1/C-P3.5–3.7 groups pass 101 of 104,
the 3 failures being exactly these cases (`addendum4-implementation-run.log`). With the three amended
copies put in place temporarily, the C-C.R1 groups pass **40 of 40**
(`trial-with-proposed-a-c.r1-4.log`); the frozen files were then restored with `git checkout` and
their digests re-checked (the "now" column above).

## What the Planner decides

1. Authorize the three diffs as written (one re-freeze, applied before the consolidated
   qualification); or
2. another disposition. Keeping the old assertions would require the destructive removal the
   Planner has ruled out.
