# R-P2.9-4: frozen-test amendment request (C-P2.9-R1 §4.5, unit)

- Prepared by: the writing agent (Implementer), 2026-10-20.
- Status: **APPROVED as written** by the human owner (`.local/plans/phase-02_update3.md`).
  Applied and re-frozen as C-P2.9-R1 §4.6.
- File: `test/unit/Lockstep/Kernel/RemediationThirdReviewTest.hs`, frozen as `2514ed59…`.

## 1. The defect, which is mine

The case "a pending intent with an attestation record needs it too" ends with a control
assertion. It is meant to show that a pending intent **without** an attestation record is
carried without the acknowledgment:

```haskell
checked p request @?= Right ()
```

The file's shared `request` fixture sets `requestAttested = True`. So the line asserts the
opposite of its intent, and it contradicts the case's first line. P2 correctly answers
`Left CarryNotAcknowledged`.

In the pre-freeze baseline the case stopped at its first assertion, line 44, as expected
before P2. The defect at line 46 was hidden. The first full run after P2
(`r1-evidence/third-review-first-run.log`) gives 674/675 unit tests; this is the one failure.

## 2. Proposed diff (one line, nothing else)

```diff
         checked p request {requestAttested = True, requestAcknowledged = True} @?= Right ()
-        checked p request @?= Right ()
+        checked p request {requestAttested = False} @?= Right ()
```

The assertion still checks what its case names. It weakens nothing: the refusal and the
acknowledged carry are asserted unchanged on the two lines above it.

## 3. Lesson

A baseline failure at an earlier line does not show that the later lines are right. Before a
freeze I now check each assertion against its fixture, not only that the case fails.

## Decision requested

Approve R-P2.9-4 as written. If you approve it, I will apply it, re-freeze the file, rerun the
full check and the Linux clone, and commit. Still pending: **R-P2.9-3**
(AC-B1-03/04, revision 11 → 12), which B1 run 3 needs.
