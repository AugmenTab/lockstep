# Review — C-P6.10b Nonprivileged host-boundary safeguards

- Reviewed: `74644a8` against `contract-b.md`, `amendments-b.md` and `design.md` §1, §4, §6, by an independent
  read-only agent (no runs, no host probing), 2026-11-15. The Implementer does not accept this subphase.
- Held: every error path traced fails closed (`set -u` without `-e` included), `refuse` never runs in a subshell,
  temp files and traps are correct, the expectation record's checks (empty digest, duplicates, line count,
  symbolic links), the anchored `Status: Enabled`, GNU/BSD portability and bash 3.2. Existing attended callers
  (`check-capsule-runner`, `-vm`, `-recovery`, `-lan` P1–P9) are unchanged: with no record the attestation stops at
  `boundary-expected-missing` before any pfctl, and attended mode exits 0.

**Bottom line.** The attestation is a necessary, not yet sufficient, condition for unattended runs: findings 2–4
show policy changes it cannot see. Nothing is unsafe today (no boundary is installed, and unattended execution is
BLOCKED until D6-SEC and P6.10c), but P6.10c must extend the attestation before an unattended run relies on it.

## Findings and dispositions

| # | Severity | Finding | Disposition |
|---|---|---|---|
| R-P6.10b-1 | High | `runtime-user-wrong` checks only who owns the runtime state directory, by name; hostagents can still run as the owner (e.g. a non-recursive `chown`, or capsules not yet migrated), so the rules match nothing while the attestation passes. | **Fixed:** the owner is compared by uid with the boundary user's uid (a user that does not exist owns nothing), and the preflight checks the uid each running capsule's hostagent runs as (`LIMA_HOME/lockstep-CAPSULE/ha.pid`), `host-boundary-runtime` FAIL unattended / WARN attended. |
| R-P6.10b-2 | High | The digest covers rule text, not table contents: editing `<lockstep_private>` (or adding to the `persist` `<lockstep_dns>`) leaves the digest unchanged. | **Open (P6.10c):** digesting `pfctl -a ANCHOR -s Tables` / `-t NAME -T show` (or literal address lists in the rules) needs pfctl commands the frozen check (B12) does not allow; amend in P6.10c with the installed boundary. |
| R-P6.10b-3 | High | The anchor can be loaded but never evaluated: the main ruleset may lack `anchor "com.lockstep.capsule"`, an earlier `quick` rule may bypass it, or `set skip on lo0` may disable filtering of host-local traffic. | **Open (P6.10c):** also attest the main ruleset (`pfctl -s rules`) and lo0's skip flag (`pfctl -s Interfaces -v`); B12 amendment. |
| R-P6.10b-4 | Medium | Nothing ties the uid in the rules (`user = 499`) to `capsule-user`; a recreated user with another uid still passes. | **Open (P6.10c):** require `user = <uid of capsule-user>` on every rule; conflicts with the frozen B1 fixture (`capsule-user` = the test's own user, rules `user = 499`), so it needs an amendment of the frozen check. |
| R-P6.10b-5 | Low–Medium | Any anchor name is accepted in the record, so another anchor's rules could be attested. | **Fixed:** only `com.lockstep.capsule`. |
| R-P6.10b-6 | Low | `pfctl` is resolved from `PATH`; an owner-user process could plant one earlier on `PATH`. The guest cannot. | **Recorded risk** (as the `netstat` precedent); pinning `/sbin/pfctl` conflicts with the frozen check's stand-in and is a P6.10c amendment. |
| R-P6.10b-7 | Low | The preflight counts any non-zero attestation exit as a failure but names none when the script did not run (126/127/64). | **Fixed:** `FAIL host-boundary: the attestation did not run (… exited N)`. |
| R-P6.10b-8 | Low (docs) | If `/dev/pf` is root-only (M7), the guide's "record the digest the preflight prints" never works; the design's "never consulted for unattended runs" differs from the code (the LAN exception still passes `host-network-exposure`; not fail-open, since `host-boundary` must also pass). | **Fixed (docs):** the guide says how to take the digest with the same normalization; the design wording is noted here. |

## Full check of the implementation

`74644a8` (`scripts/check --integration`): all passed: format, lint and static checks (including
`check-host-boundary` 42/42), build, unit (1078), no-live-model guard, integration + backup/restore (699). Log:
`.local/evals/phase-06/p610b-full-check.log`.

## Remediation tests (frozen RED against `74644a8`)

- `scripts/lib/check-host-boundary-review` (run by `check-step lint`) — SHA-256
  `d4e08fef77470ba3950dcb3e655c6bd546b17352b9b319492ed591836599bd37`
- RED in the dev container: 6 of 9 fail. Passing guards: the control (Lockstep's anchor passes), an anchor name
  with `/` (already refused by the character set), a user that does not exist (already refused by name).
- R3/R4 check the preflight by its text (as B14 does): the hostagent check needs running capsules, so its behaviour
  is qualified only by the attended P6.10c run. Disclosed as a limit of this model-free check.
- Disclosure: the check was tried first against the draft remediation in `.local/p610b-trial/` on macOS: 9/9, and
  the frozen C-P6.10b check 42/42 there. No case changed after that trial.

## After remediation

- Remediation `6b0a6c6`: `check-host-boundary` 42/42, `check-host-boundary-review` 9/9.
- Full check of `6b0a6c6` (`scripts/check --integration`): all passed: format, lint and static checks (both checks
  above), build, unit (1078), no-live-model guard, integration + backup/restore (699). Log:
  `.local/evals/phase-06/p610br-full-check.log`.
- C-P6.10b is locally qualified as a nonprivileged safeguard; R-P6.10b-2, -3, -4 and -6 are open for P6.10c (they
  need the owner's D6-SEC grant and an amendment of the frozen check). Owner acceptance is pending.
