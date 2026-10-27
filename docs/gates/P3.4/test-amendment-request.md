# Frozen-test amendment request — C-P3.4 `HandoverTest.hs` (for the owner)

- Status: **APPROVED AND APPLIED** (Planner disposition, 2026-10-27). Raised 2026-10-26 by the
  writing agent, manual.
- Affects: `test/integration/Lockstep/HandoverTest.hs`, frozen in C-P3.4 §4 at
  `eb856b5ade7e524d399b448d7203e638e1bcf874dcd726648de01fc61bbcfd6c`; re-frozen at
  `8a9903a9bcac3b422e6428b2cf6fe9aa85654eb8b52f4cf48fccea456bd61da0` (C-P3.4 §4, amendment A1).

## The defect

Lines 129 and 147 take the request id from the pane's `202` answer `{"id":"<32 hex>"}`:

```haskell
rid = BS8.unpack (BS.take 32 (BS.drop 7 (snd (BS.breakSubstring "\"id\":\"" (responseBody started)))))
```

`"\"id\":\""` is 6 bytes (`"id":"`), so `BS.drop 7` also drops the first hex digit of the id, and
`BS.take 32` ends on the closing quote. `await` then waits for `results/<wrong id>.res`, which can
never exist, and fails after 30 s with "no result within 30 s".

No correct implementation can pass these two cases: the pane's answer would have to carry one
extra character before the id. Changing the API to fit the defect would weaken the test's intent,
so it was not done.

Affected cases (both fail only for this reason):

1. "the pane hands the address over once, to its own session" (line 129)
2. "a forged hand-over file is not handed over" (line 147)

Evidence that the behaviour itself works: the same run passes "the helper issues a one-time
token into a private hand-over file, never into the result", "without a running service nothing
is issued" and the full real-browser journey (pane → Open Lockstep → Home → … → sign-out), which
goes through `/api/open-application`, the helper and `/api/handover/<id>` end to end.

## Requested amendment (exact)

On lines 129 and 147, `BS.drop 7` → `BS.drop 6`. Nothing else changes. The file would then be
re-frozen with its new SHA-256 recorded in C-P3.4 §4 as an owner-authorized amendment.

## How it was missed

The pre-freeze integration baseline (C-P3.4 §4) expected these two cases to fail ("no hand-over
result") because the pane had no hand-over yet; the extraction defect produced the same symptom
and was not separately checked. Recorded in the retro.
