# Amendment request A-C.R1-2 — a defect in the frozen C-C.R1 page test (for the Planner)

- Status: **REQUESTED, NOT APPLIED.** The frozen file is unchanged (digest
  `4015a2835ae35a6ec3dc018efb31aa0d12e78fc7244203b1cd62a1676c4bd41d`, C-C.R1 §4).
- Raised 2026-10-27 by the writing agent (Implementer, manual), after the first run against the
  implementation.

## The defect

`test/integration/Lockstep/GateCRemediationPageTest.hs`, case "out-of-range task and project
revisions are a form error and change nothing (R3)", sends the same list of bad values to three
fields. One value, `4294967297`, is out of range for the Ticket revision (`ticket_revision`,
PostgreSQL `integer`), but **in range** for the task and project `revision` fields, which the frozen
contract defines as `bigint` (C-C.R1 R3: "the project and task `revision` fields (0…2⁶³−1)"). The
implementation follows the contract, so the edit is answered `stale-revision` (a correct answer: no
task is at revision 4294967297) and the case fails on its own fixture. It is the test's error, made
when it was written, not the product's: the pre-freeze baseline could not show it, because the
unfixed code failed that case earlier on the same line.

Run against the implementation (`first-implementation-integration-run.log`): 20 of 21 C-C.R1 cases
pass; this is the one failure.

## Exact diff requested

`docs/gates/C-R1/a-c.r1-2.diff`:

```diff
@@ -166,12 +166,16 @@ tests =
             ( \bad -> do
                 decided <- post svc ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", bad), ("action", "ready")]
                 has (responseBody decided) [unreadable]
+            )
+            ["4294967297", "2147483648", "18446744073709551617", " 1", "1x", "-1"]
+          traverse_
+            ( \bad -> do
                 edited <- post svc ("/app/api/tasks/" <> tid <> "/edit") [("revision", bad), ("title", "Buy rye bread"), ("acceptance", ""), ("priority", "normal")]
                 has (responseBody edited) [unreadable]
                 connected <- post svc ("/app/api/projects/" <> pid <> "/connect") [("revision", bad), ("folder", "later")]
                 has (responseBody connected) [unreadable]
             )
-            ["4294967297", "18446744073709551617", " 1", "1x", "-1"]
+            ["9223372036854775808", "18446744073709551617", " 1", "1x", "-1"]
```

Each field then gets values outside its own stored range (2³¹ and 2³² + 1 for the Ticket revision;
2⁶³ and 2⁶⁴ + 1 for the bigint revisions) plus the same non-decimal spellings. Nothing else in the
file changes; the amended file's SHA-256 would be
`ad05170cefeba7fd9ddf702a3392bd5b6a962c3a3f5c91a233fdbb449bd6806e`.

## Trial with the amendment (not applied)

The amended file was put in the working tree for one run of the C-C.R1 groups and then restored
(`git restore`; the frozen digest above was checked afterwards):
`docs/gates/C-R1/trial-with-proposed-a-c.r1-2.log`, **21 of 21 passed**.

## What the Planner decides

1. Approve the diff (then it is applied, re-frozen at the digest above, and the qualification
   repeated), or
2. keep the test and narrow the contract instead: bound the task and project `revision` fields to
   0…2³¹−1 as well (a contract amendment to R3; the code change is two constants), or
3. another disposition.

The writing agent's recommendation is 1: the contract states the stored range, and the test was
meant to probe out-of-range values for each field, not to narrow the bigint fields.
