# Amendment to a frozen check for C-P4.L.R3 — for the owner's authorization

- Status: **APPROVED and applied.** Authorization record: the owner referred the decision to the Planner
  (2026-10-30; package `.local/planner/A-P4.L.R3-1-amendment-package.md`); relayed by the owner in the session:
  "Planner decision: APPROVE A-P4.L.R3-1 in full, as proposed." Applied exactly as proposed; the file's sha256 after
  applying is `85b0a484f35421860fad8d97bc21616d4c2b306839657b2d5f01a226af44ae8d`, equal to the proposal. No other
  frozen test changed. The approval does not authorize installation, real credentials, provider calls, the smoke or
  Gate C-EXEC acceptance. Before approval the frozen file was unchanged; the amended version is a draft at
  `.local/p4lr3/amend/check-live-impersonation`. Prepared 2026-10-30 by the writing agent (Implementer, manual) under
  `.local/plans/phase-04_update5.md` ("Extend `check-live-impersonation` to prove that malicious tool subprocesses
  cannot extract the conversation state or impersonate the CLI").

## A-P4.L.R3-1 — `scripts/lib/check-live-impersonation` (C-P4.L.R2 §9)

- Original: sha256 `1cb2d83c6c5edb3d85bde8ff75c515465b952b02037aacb7f69d83dacee52c23` (frozen `307897e`).
- Proposed: sha256 `85b0a484f35421860fad8d97bc21616d4c2b306839657b2d5f01a226af44ae8d`.
- Full diff: `docs/gates/P4.L.R3/A-P4.L.R3-1.diff`. Three parts:
  1. **Section 2 added** (the extension the handoff asks for): a stand-in with secret ids
     (`scripts/lib/live-standin-secret`) and a hostile program in the repository (`scripts/lib/live-memory-thief`), both
     frozen with the contract; 31 new expectations (contract §4). `implement` gains one line: a run's tree may also hold
     the files of a `seed` directory (the repository's own code); empty for section 1, so section 1 runs as before.
  2. **One expectation of section 1 becomes a recorded note.** Section 1 *hands* the impersonator the run's tool-call
     ids (the stand-in's ids are fixed and written into the impersonator). Given the ids, the proxy admits a
     continuation for as long as the run's allowances last; no proxy rule can tell it from the CLI, so the line
     "at most one impersonated request is admitted (owner condition 1; BLOCKING if not)" can never pass and no longer
     measures the owner's bound. The bound is now isolation's: section 2 expects **no** impersonated request admitted
     when the program must learn the ids itself. The note keeps the measured value in the results.

     ```diff
        if [ "$n" = 2 ]; then
     -    expect "$label: at most one impersonated request is admitted (owner condition 1; BLOCKING if not)" \
     -      test "$(sed -n 's/^impersonated-2 //p' "$state/runner/work/$run/output/impersonation.txt")" != 200
     +    printf 'NOTE %s\n' "$label: with the ids handed to it, the second impersonated request answered $(sed -n 's/^impersonated-2 //p' "$state/runner/work/$run/output/impersonation.txt") (the bound is isolation's: section 2)" \
     +      | tee -a "$results"
        fi
     ```
  3. The header comment says so.
- Every other section 1 expectation (12) is unchanged.
- Trials:
  - amended vs the current code (`7018df9`, no isolation): **RED**, 16 failures, each the finding
    (`.local/p4lr3-red-baseline.log`; `.local/evidence/live-impersonation-20261030t162655z/`): the program reached the
    CLI by `/proc/1/mem` (1.9 GB read), `process_vm_readv`, `ptrace` attach and seize, `environ`, `fd`, `cwd`, its files,
    its identity and a signal; **it found the run's real, random tool-call id in the CLI's memory**
    (`toolu_01337hldY5KubgkVGiH6zgMP`, the stand-in's first issued id) and **its impersonated request was admitted
    (200)**; two requests reached the upstream; the CLI ran as the tools' identity and dumpable. Passing already:
    `pidfd_getfd` and a user namespace (Docker's seccomp), the fail-closed stop, and ordinary development. Section 1:
    12 of 12 and the note (200).
  - Two test faults fixed before this baseline: the program read the CLI's pipes through `/proc/1/fd` and blocked
    until the Bash tool's two-minute limit (now regular files only, and the report is written as it goes); the run's
    outcome was compared with a wrong string.
  - amended vs the implementation: §5 of the contract (GREEN expected).
