# R-P2.3-1 — protected-test amendment request (C-P2.3)

- Prepared by: the writing agent (Implementer), 2026-10-18. **Not applied.** A frozen test may be
  changed only with the human owner's approval (PRD §6.1; the protected-test amendment protocol
  used for R-P1.3-1 and R-P1.5-1). Status: `REQUESTED`.
- Contract: `C-P2.3@v1`, frozen at `493036a`.
- File: `test/integration/Lockstep/ProfileRegistryTest.hs`, frozen SHA-256
  `305cc30f9d9d62bde7a0e987086a3fd6ca07991d2fecc269b7c1dfd09d04b139`.
- Test: "a tampered stored document is an integrity failure, never used".

## Defect

To simulate tampering, the test disables the immutability trigger, edits the stored document and
re-enables the trigger in **one** `adminExecute` call:

```
"ALTER TABLE lockstep_profiles DISABLE TRIGGER USER; UPDATE …; ALTER TABLE lockstep_profiles ENABLE TRIGGER USER"
```

`adminExecute` runs its text through Orville as a single prepared statement, and PostgreSQL
refuses several commands in one prepared statement (`42601: cannot insert multiple commands into a
prepared statement`). The test's own setup therefore throws before Lockstep is exercised. No
production behaviour can change this outcome. The pre-freeze baseline did not reach this line
(every case stopped at the then-missing `profile` command), and I checked it only by reading, so
I missed it. Evidence: `evidence/check-integration-unamended.log` (78 of 79 integration tests
pass; this one fails with the exception above).

## Proposed amendment (setup only; no assertion changes)

Run the three statements as three `adminExecute` calls. Exact diff:
`evidence/r-p2.3-1.diff` (4 lines removed, 6 added, test setup only):

```haskell
          traverse_
            (adminExecute (scAdmin sc) (T.unpack (scDb sc)))
            [ "ALTER TABLE lockstep_profiles DISABLE TRIGGER USER"
            , "UPDATE lockstep_profiles SET document = replace(document, 'supervisor', 'none')"
            , "ALTER TABLE lockstep_profiles ENABLE TRIGGER USER"
            ]
```

The test's assertions are unchanged: `profile show` and `profile resolve` must both exit 70 with
no stdout, and stderr must mention "integrity".

## Trial

I applied the diff to the working tree, ran the group, and restored the frozen file with
`git checkout` (its SHA-256 afterwards: `305cc30f…`, unchanged). With the amendment, all 6 tests
in the group pass, including this one (`evidence/integration-with-proposed-amendment.log`).

## Decision requested

Approve R-P2.3-1 as written, or give another instruction. If approved, I will apply the diff byte
for byte, record the new digest as a re-freeze in C-P2.3 §10.1, re-run `scripts/check
--integration` and a Linux clone, and continue to P2.4.
