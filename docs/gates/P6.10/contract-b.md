# Contract — P6.10b Nonprivileged host-boundary safeguards

- Contract ID: `C-P6.10b@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06_update1.md` §7 item 7 ("Prepare and qualify nonprivileged P6.10 safeguards
  without installing a host firewall"); `docs/gates/P6.10/design.md` §6.
- Basis: `phase-6` after C-P6.9 qualified (the record of the R-P6.9 full check, after `ef3c64a`).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.
- Not authorized and not done: no host rule, user, launchd job or file outside the repository is created or
  changed; no `sudo`; no `pfctl` is run against this Mac by any check (a stand-in answers); M1–M3 (attended) are not
  run.

## 1. What this adds

| # | Decision |
|---|---|
| B1 | **Attestation** `scripts/capsule/host-boundary --helper-state DIR [--unattended]` reads pf's status (`pfctl -s info`) and the anchor's loaded rules (`pfctl -a ANCHOR -s rules`), read-only, and compares them with the owner's recorded expectation `DIR/capsule/host-boundary` (`lockstep-host-boundary 1`, `anchor`, `capsule-user`, `rules-sha256`; a regular file of mode 0600, written when D6-SEC installs the boundary). It prints one `PASS`/`FAIL`/`WARN host-boundary` line and, when the rules were read, a `NOTE` with their digest. |
| B2 | **Refusals, named:** `boundary-expected-missing`, `boundary-expected-not-private` (mode, symbolic link, not a regular file), `boundary-expected-malformed`, `pf-unreadable` (a failing command, e.g. permission denied), `pf-disabled`, `anchor-absent` (no rules: flushed, or not loaded after a reboot), `anchor-altered` (any change, including order, since quick rules' order is policy), `runtime-user-wrong` (the capsule runtime state is not owned by the boundary's user, so the rules would not match its traffic). Only trailing blanks and empty lines are not differences. |
| B3 | **Unattended fails closed, attended is told.** With `--unattended` a refusal is `FAIL` (exit 1); without it, `WARN … (an unattended run would not start)` (exit 0). Nothing falls back to the listener exception: a `lan-exception` file changes nothing here. |
| B4 | **Preflight.** `scripts/capsule-preflight` gains `--unattended` and runs the attestation (passing it on); a `FAIL` counts as a preflight failure. Attended preflights (every existing caller) see at most a `WARN`, so no existing check changes outcome. |
| B5 | **Read-only by construction.** The attestation asks pfctl only `-s info` and `-a ANCHOR -s rules`, and never runs `sudo`. |

## 2. Not in this increment (recorded)

- **Re-attestation during a run** (design §6 item 3: halt `host-boundary-lost` at a role-invocation boundary). It
  needs the attestation's outcome where the Engine starts role invocations (the helper's capsule bridge), and an
  unattended mode that does not exist yet; it is P6.10c work with the installed boundary.
- **Whether pf's state is readable without root on this macOS** (design M7). If it is not, every attestation is
  `pf-unreadable` and unattended runs cannot start, which is fail-closed; D6-SEC must then include a root-owned,
  read-only status export. Not probed here.
- **Image provenance pin** (design §6 item 5): blocked on the owner's choice of release (D6-SEC item 5).

## 3. Mandatory tests → cases (`scripts/lib/check-host-boundary`, model-free, a stand-in pfctl)

B1 (PASS, digest NOTE), B2 (blanks), B3–B5 (expectation missing, not private, symbolic link, malformed ×3), B6
(pf unreadable ×2), B7 (pf disabled), B8 (anchor absent), B9 (altered, reordered, extra pass rule, rule removed),
B10 (runtime user), B11 (no fallback to a LAN exception), B12 (only read commands; no sudo), B13 (usage), B14 (the
preflight runs it and passes `--unattended`). Each refusal is checked unattended (`FAIL`, exit 1) and attended
(`WARN`, exit 0, never `PASS`).

## 4. Verification files

`scripts/lib/check-host-boundary`, run by `scripts/lib/check-step capsule`.

## 5. Freeze record

- Frozen file (SHA-256): `scripts/lib/check-host-boundary`
  `20dd704378bbbec424258e50d7f751571b4599e7fd6c3e68e3ab832acca6cb11`
- RED against the stub (`scripts/capsule/host-boundary` printing `PASS host-boundary`; the preflight unchanged), in
  the dev container: 38 of 42 cases fail. Passing vacuously: B1's PASS line, B2 (the stub always passes) and B12 ×2
  (the stub runs no pfctl and no sudo); each is meaningful only together with the refusal cases.
- Disclosure (the P6.6 practice): before the freeze the check was tried against a draft attestation and preflight
  change in a copy under `.local/p610b-trial/`, on macOS and in the dev container: 42/42 both. No case changed after
  that trial.

## 6. Allowed paths

New: `scripts/capsule/host-boundary`, `scripts/lib/check-host-boundary`, `docs/gates/P6.10/contract-b.md`,
`docs/gates/P6.10/review-b.md`. Changed: `scripts/capsule-preflight` (B4), `scripts/lib/check-step` (the `capsule`
step), `docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen case. Model-free; no host change. Rollback: the branch.
