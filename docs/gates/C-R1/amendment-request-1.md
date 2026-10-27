# Amendment request A-C.R1-1 — a creation key reused with different content (for the Planner)

- Status: **REQUESTED, NOT APPLIED.** Nothing below is in the code or the tests.
- Raised 2026-10-27 by the writing agent (Implementer, manual) under C-C.R1 §5.
- Authority asked for: the Planner disposition of 2026-10-27, item 9 ("A key reused with different
  input must conflict, not return another project's resource"), and its remediation discipline
  ("Any necessary frozen-artifact amendments require exact diffs, provenance and authorization").

## Why it stops here

C-C.R1 R9 implements the first half of item 9: a task creation key already used in **another**
project is refused `key-conflict` and shows nothing of that project. The second half, refusing a
key reused **with different content in the same place**, contradicts two frozen tests that assert
the opposite, and the contracts they implement:

| Frozen file | Recorded digest (unchanged today) | Frozen contract text |
|---|---|---|
| `test/integration/Lockstep/ProjectsTest.hs` (C-P3.5 §4) | `0e47aac63eb0874a85ed0faa7d1bb7c7ef5951e42d8d4c8188798bb2bade5342` | J2: "A repeated creation key returns the project it created and creates nothing." |
| `test/integration/Lockstep/TasksTest.hs` (C-P3.6 §4) | `181cb31396381fe46a32c53de8f411cc1168320eb6bc9fa04cadc7a4bd4266ca` | K2: "A repeated creation key returns the task it created." |

Implementing it without the amendment would turn both cases red.

## Exact diffs requested

```diff
--- a/test/integration/Lockstep/ProjectsTest.hs
+++ b/test/integration/Lockstep/ProjectsTest.hs
@@ -208,12 +208,12 @@
           count sc "lockstep_engineers" >>= (@?= 0)
           listDirectory (scRoot sc) >>= (@?= [])
-    , testCase "a repeated creation key returns the first project and creates nothing" $
+    , testCase "a repeated creation key returns the first project and creates nothing; other content is a key conflict" $
         withScenario $ \sc -> do
           first <- created sc (folders sc []) "k-same" "Garden" NewFolder
           again <- created sc (folders sc []) "k-same" "Garden" NewFolder
           projectId again @?= projectId first
-          other <- created sc (folders sc []) "k-same" "Something else" DecideLater
-          projectId other @?= projectId first
+          other <- create sc (folders sc []) "k-same" "Something else" DecideLater
+          fmap projectId other @?= Left "key-conflict"
           count sc "lockstep_projects" >>= (@?= 1)
           count sc "lockstep_repositories" >>= (@?= 1)
           listDirectory (scRoot sc) >>= (@?= ["garden"])
```

```diff
--- a/test/integration/Lockstep/TasksTest.hs
+++ b/test/integration/Lockstep/TasksTest.hs
@@ -144,8 +144,9 @@
-    , testCase "a repeated creation key returns the first task and creates nothing" $
+    , testCase "a repeated creation key returns the first task and creates nothing; other content is a key conflict" $
         withScenario $ \sc -> do
           p <- project sc "Kitchen"
           first <- made sc "same" p "Buy bread" Normal []
           again <- made sc "same" p "Buy bread" Normal []
-          other <- made sc "same" p "Something else" Low []
-          (taskId again, taskId other) @?= (taskId first, taskId first)
+          taskId again @?= taskId first
+          other <- new sc "same" p "Something else" Low []
+          fmap taskId other @?= Left "key-conflict"
           count sc "lockstep_tickets" >>= (@?= 1)
```

Contract text that would change with it: C-P3.5 J2 and C-P3.6 K2, "A repeated creation key returns
the project (task) it created" → "… returns it when the request is the same; the same key with
other content is refused `key-conflict` and creates nothing". After approval the two files would
be re-frozen at their new digests in their contracts' §4, as A1 was for `HandoverTest.hs`.

## The code change it would authorize (not written)

- Migration 17: `creation_digest text` (64 hex, NULL for rows made before it) on `lockstep_projects`
  and `lockstep_project_tasks`; no existing row changes.
- The digest is SHA-256 of a canonical text, as C-P3.8 M2 does for decisions: for a project its
  name, outcome and folder choice; for a task its project, title, acceptance, priority and sorted
  dependencies.
- A repeated key replays only when the stored digest equals the new one; otherwise `key-conflict`.
  A row without a digest (made before migration 17) replays only for the same project, as R9 does
  today. Words for projects: "This form was already used for another project. Nothing was changed.
  Open New project again."

## What the Planner decides

1. Approve the two diffs and the contract wording (then the change above is implemented under a
   C-C.R1 addendum, with the same Mac and Linux qualification), or
2. keep the C-P3.5/C-P3.6 rule (same key → the first result, whatever the content) and record
   item 9 as met by R9 only, or
3. another rule.
