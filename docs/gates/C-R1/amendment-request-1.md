# Amendment request A-C.R1-1 — a creation key reused with different content (for the Planner)

- Status: **APPROVED IN PRINCIPLE** (Planner, 2026-10-27, `.local/plans/phase-03_update3.md`:
  "replay keys must be bound to the original request identity and content, with conflicting reuse
  refused"). **Not authorized for editing; not applied.** Nothing below is in the code or the
  frozen tests. Final authorization packet: "For final authorization" at the end.
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

## For final authorization (prepared 2026-10-27, after the Planner's approval in principle)

The diffs above were superseded by the exact `git diff --no-index` output of the frozen files
against amended copies (`.local/amend-c-r1/`, outside the test tree; the frozen files were not
touched): `docs/gates/C-R1/a-c.r1-1-projects.diff` and `docs/gates/C-R1/a-c.r1-1-tasks.diff`. They
change one case each and nothing else.

| File | Frozen digest (now) | Digest after the amendment | Recorded in |
|---|---|---|---|
| `test/integration/Lockstep/ProjectsTest.hs` | `0e47aac63eb0874a85ed0faa7d1bb7c7ef5951e42d8d4c8188798bb2bade5342` | `be24e197af637c96f82930ca190b204d53504041bc6c12c63802908c92d50d83` | C-P3.5 §4 |
| `test/integration/Lockstep/TasksTest.hs` | `181cb31396381fe46a32c53de8f411cc1168320eb6bc9fa04cadc7a4bd4266ca` | `e4e29fc2b8e3ddde11ecf4220676c2695bcd5c4bd297b6a3ae819eb5de2c4e56` | C-P3.6 §4 |

Contract assertions affected:

| Contract | Now | After |
|---|---|---|
| C-P3.5 J2 | "A repeated creation key returns the project it created and creates nothing." | "A repeated creation key returns the project it created and creates nothing when the request is the same; the same key with other content is refused `key-conflict` and creates nothing." |
| C-P3.5 §3 (`ProjectsTest.hs` row) | "repeated creation key" | "repeated creation key (same content replays, other content `key-conflict`)" |
| C-P3.6 K2 | "A repeated creation key returns the task it created." | "A repeated creation key returns the task it created when the request is the same; the same key in another project or with other content is refused `key-conflict`." |
| C-P3.6 §3 (`TasksTest.hs` row) | "repeated creation key" | as for C-P3.5 |
| C-C.R1 R9 | first half done, second half stopped (§5) | both halves done; §5 closed |

Production change that goes with it (described above; not written): migration 17
(`creation_digest`), the canonical project and task request texts, the replay rule, and words for
projects. Tested by the two amended cases; the amended copies have **not** been compiled or run
(no build or test was started under the current stop instruction).

Expected behaviour of the amended cases: against today's code (`e1c56ef`) both **fail** (the same
key with other content still returns the first project or task); with the production change both
should pass. Both are to be shown in the next qualification, before and after.
