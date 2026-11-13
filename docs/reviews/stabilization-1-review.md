# Independent review: post-Phase-5 stabilization (S1–S4)

- **Reviewer:** an independent read-only agent, 2026-11-13. It had the code and the handoff, not the Implementer's
  conclusions. Scope: commits `3196dd1`, `05f1762`, `731eed5`, `f05285c` on `62f353a`. It ran nothing.
- **Result:** no HIGH. One MEDIUM, one LOW–MEDIUM, six LOW. Both of the higher findings are fixed.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | `protected-test-changed` at verify offered a retry that re-verifies the same candidate commit, so it can only halt again; `retry-model.md` overclaimed "none is known-impossible" | **Fixed.** That halt now offers only *stop* (`haltChoices`; unit test). The question says why. `retry-model.md` and contract S2.5 corrected; the remaining `HaltRefused` retries re-run a role or re-check a condition the operator can fix |
| 2 | LOW–MED | `egress.refused` sorted and cut at 80 characters, so the renewal host could be crowded out, and a too-long first entry read as `-` | **Fixed.** The renewal host's entry always comes first; a cut list ends `more`; it is never `-` when refusals happened. New `scripts/lib/check-refused-hosts` (8/8) runs the helper's own function on the host's bash 3.2 |
| 3 | LOW | Pre-S2 requests still offer retry at `reproduction-missing`; the halt text claimed a command ran even for a legacy no-command halt | Text **fixed** (now true in both cases). The legacy retry is kept and documented: under the new rule it proceeds |
| 4 | LOW | `changeScope` ignores gitlinks | Accepted: snapshots exclude submodules, so a candidate cannot carry one. Recorded as a limitation |
| 5 | LOW | The needs-human review record could exceed 20 reasons or 4000 characters | **Fixed.** At most 19 of the Reviewer's reasons plus one of Lockstep's, cut to 4000; at most 20 paths named, then "and N more" |
| 6 | LOW | The `scripted` exemption is a name match in production logic | Accepted for now: production builds only `claude-code` and `claude-code-capsule` adapters (`app/lockstep/Main.hs`), and a missing row defaults to required. The exemption exists so frozen fixtures keep passing. A typed flag on `Adapter` is the better design; it is left out to keep this pass narrow |
| 7 | LOW | The contract named a test file that does not exist; `capsule-preflight` hard-codes the image tag | Contract **fixed**. The tag duplication is noted (one more place to change on a CLI bump) |
| 8 | LOW | Per-run `.refusals` files accumulate | Accepted: they are evidence beside the per-run summaries, which accumulate in the same way by design |
