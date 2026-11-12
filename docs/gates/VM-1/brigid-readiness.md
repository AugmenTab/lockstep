# P5.12 Brigid: attended live-run readiness packet (Phase 5 update 2 §6)

- **For:** the owner. **Prepared:** 2026-11-11, branch `phase-5` (this commit).
- **Not done, by design:** no real-provider call, no Brigid transaction, no project registered in your Lockstep
  service, nothing installed or changed on the host outside this repository. The live run needs **your separate
  authorization** (phase-05 §16).
- **LAN prerequisite:** satisfied for the attended Brigid experiment, under the conditions in
  `lan-exception.md`. General host-LAN isolation is **not** claimed. A host-enforced boundary is deferred work,
  required before unattended or multi-project use.

## 1. Revision and capsule state

| Item | State |
|---|---|
| Lockstep | `phase-5` at this commit; `scripts/check` green on it (unit 870/870); integration 571/571 at `70368a6` (no Haskell changed since) |
| Template | current (`networkOpts.hostLoopback: false`; `needrestart` list-only, so a guest's `apt` cannot restart sshd and cut its own session) |
| `brigid1`, the Engineer's capsule | `large` (6 vCPU, 12 GiB, 100 GiB, 7200 s per command), 16 GiB swap, audited, current. **No Haskell toolchain**, on purpose: the acceptance requires the Engineer to set it up itself (§3) |
| `brigidv`, the verification capsule | `large` + 16 GiB swap; Stack 3.11.1, GHC 9.10.3, Brigid's dependencies built; trusted snapshot **`verify`** |
| `vmq1`, `vmv1` | the qualification capsules (synthetic project); not used by Brigid |

## 2. Project workspace

- **Basis:** `331dcc0`. GitHub `AugmenTab/brigid` `main` is still `331dcc0` (`git ls-remote`, 2026-11-11), and is
  the recorded basis.
- **Working copy:** a fresh clone from GitHub at `.local/brigid/source`, plus a bundle at
  `.local/brigid/brigid-331dcc0.bundle`.
- **Your checkout** `/Users/tab/personal/brigid` was not modified. It was only read, before the 2026-11-11
  rule about reads outside the repo.

## 3. Toolchain readiness

- **Verification** (`brigidv`), set up by the operator through `capsule-runtime run`. No model was involved.
  - **Setup script:** `.local/brigid/verify-setup.sh`, copied to `evidence/update2-brigid/`. It does three
    things:
    - Ubuntu packages for Brigid's C libraries (`libphonenumber-dev`, `libprotobuf-dev`, as its `Dockerfile`
      installs);
    - the official Stack installer;
    - `stack setup` for `stack-ghc-9.10.yaml`.

    It took 2.5 min.
  - **Brigid's real `scripts/test` at the basis: all 736 tests passed** (`evidence/update2-brigid/verify-test-basis.out`).
  - **The path verification will use**, end to end:
    1. A marker written after the snapshot.
    2. `restore verify`: the marker was gone.
    3. A fresh import of the tree, with no build output.
    4. `scripts/test`: **passed in 2 min** (`evidence/update2-brigid/verify-from-snapshot.out`).
  - **Found and fixed while preparing it:**
    - The first cold build was killed for lack of memory (`ExitFailure -9`). GHC compiles Brigid's modules
      in parallel (`-j`), and that ran out of the 12 GiB without swap. Both capsules now have 16 GiB of swap.
    - `needrestart` restarted sshd in the middle of an `apt` install and ended the session. The template now
      prevents that.
- **Engineer** (`brigid1`):
  - It gets the same template, swap and network.
  - Its route to a working toolchain is the one measured above: apt, the Stack installer, `stack setup`, then a
    cold build of the dependencies. Expect about 10 minutes, within the 7200 s per-command limit. This is not a
    stall.
  - Guest DNS, HTTPS, `apt` downloads and Docker pulls work (`check-capsule-lan` G2).

## 4. Preflight (the run's own check), with the scoped exception

`evidence/update2-brigid/readiness/preflight.txt` comes from a real helper in capsule mode, with Brigid's
capsules, a stand-in Lockstep project id, and the exception carrying that same id:

- **Result: 0 failures.** Every check passes: config, health, ownership, template, host-loopback isolation,
  workspace, disk, guest Docker, no credential in the guest, no host mounts, the bridge, tool routing, the
  verification environment, `lan-exception` and `host-network-exposure`.
- **Exception notes:** each accepted listener is named, and they are only the reviewed ones (`lan-exception.md` §1).
- **Rerun after update 3** (fail-closed inventory), 2026-11-12: 0 failures again, with 11 accepted listeners,
  all reviewed (`evidence/update3-brigid-readiness/preflight.txt`). If `netstat` fails or its listing is not
  recognized, `host-network-exposure` now fails with the cause, whatever the exception says.

## 5. What you do for the attended run (in order)

1. **Install this revision** of Lockstep the usual way (`scripts/service install`).
   - The helper's runner image changed since your last install. Rebuild images before starting the helper
     `--runner`, and restart the helper after any rebuild (the Gate C lesson).
   - I did not check or touch the installed service.
2. **Register Brigid** in Lockstep.
   - Its project folder is a clone of the basis: `git clone .local/brigid/brigid-331dcc0.bundle` or from GitHub.
   - Allow execution, and note the project id.
3. **Capsule config.** In the helper state, write `capsule/config` (mode 0600):
   ```
   lockstep-capsule 1
   runtime-state /Users/tab/personal/lockstep/.local/cvm
   capsule brigid1
   project brigid
   verify-capsule brigidv
   lockstep-project <Brigid's project id>
   ```
4. **The exception.** Copy `.local/brigid/lan-exception` to `capsule/lan-exception` (mode 0600), with
   `@LOCKSTEP_PROJECT@` replaced by the same id. It **expires 2026-11-13T23:00Z**. After that, write a new one
   (at most 72 h ahead) or preflight refuses.
5. **Keep `development-easy` stopped** for the run. If it is running, preflight refuses (its ports are not in
   the exception).
6. **Start the helper** with `--runner` and your provider configuration. Native subscription auth is as in
   Gate C: run `provider-auth-login` in a real terminal if the token has lapsed.
7. **Run** `scripts/capsule-preflight --helper-state <DIR> --repo <Brigid's project folder>`. It must report
   0 failures.
8. **Authorize the live run** and hand over the bug (phase-05 §16 ticket).

## 6. Remaining blockers

1. **Your authorization of the real-provider session.** This is the only blocker.
2. **Operator steps 1–7 above.** They need your installed service and your helper state, which are outside
   this repository, so I did not do them unattended.

## 7. Known limits for this run

- The live capsule path has only run against the stand-in. Brigid is its first use with a real model.
- Preflight checks once, at start. A service that starts listening on the LAN during the run is not blocked.
  You attend.
- Brigid's other `stack-ghc-*.yaml` files (9.6, 9.8) are not set up in the verification capsule. `scripts/test`
  uses 9.10 only.
