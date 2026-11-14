# C-P6.3 — frozen-test amendment request (owner authority required)

## A-P6.3-1 (AUTHORIZED by the owner, 2026-11-14, `.local/plans/phase-06_update1.md` §2; APPLIED)

- Applied exactly as proposed below: two principal literals in `questionAnswered` (line 234 `"human"` → `"Human"` in
  the principal position; line 241 `"supervisor"` → `"Supervisor"`). The message kind `"human"` and every other line
  are unchanged; no implementation change.
- Digest of `test/integration/Lockstep/InboxTest.hs`: before
  `55809fa3d1849045b445d55f6c0103f9f380595bafeee51bc04f1f5cc50dafbb`, after
  `d8ac25b083ff56865c6252677c9fc5b28d1d1f86ddfd8ec096153121992359e9` (supersedes the C-P6.3 §4 digest for this file).
- Results: see `review.md` "After A-P6.3-1".

### Original request

- **File:** `test/integration/Lockstep/InboxTest.hs`, case "a person's question gets one read-only Planner answer,
  which decides and resumes nothing (I3, I4, I5)" (`questionAnswered`).
- **Defect in the frozen test, not in the implementation.** The case compares a stored message's principal with
  `"human"` and the Planner answer's principal with `"supervisor"`. C-P4.3 stores the principal as
  `Lockstep.Kernel.Transition.principalLabel` gives it: `"Human"` and `"Supervisor"` (`src/Lockstep/Kernel/Transition.hs:89-97`),
  as every earlier conversation test expects. The implementation stores exactly that; it would be wrong to change
  C-P4.3's stored representation to satisfy a mistaken literal.
- **Observed:** `expected: ("human","human","What happens if I retry?")`, `but got: ("human","Human",…)`
  (`.local/evals/phase-06/p63-trial-integration-1.log`). The other 8 cases of the file pass, and 6/6 unit cases.
- **Proposed amendment:** in that case only, `"human"` → `"Human"` in the principal position of the first tuple
  (the kind stays `"human"`), and `"supervisor"` → `"Supervisor"` in the answer's tuple. No other line changes.
- **Effect if not approved:** this one case stays FAILED; everything it would check after its first assertion
  (the answer is recorded, the request stays open, the fix stays halted, no resume) is also covered by the
  `authority`, `idempotent` and `distinct` cases, which pass.
- The writing agent has **not** edited the frozen file (its digest is unchanged).
