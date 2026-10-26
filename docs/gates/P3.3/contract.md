# Contract — P3.3 Guided installation, upgrades and recovery

- Contract ID: `C-P3.3@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.3; PRD v0.3 FR-UX-03, NFR-17; Plan v0.3 §4 P3.3 ("reuse Phase
  1/2 scripts and tested primitives behind an allowlisted authority boundary rather than
  introduce a second orchestration kernel") and DG-16; owner decision DR-P3.1 §6 (install,
  upgrade, migrate and restore need an explicit decision in the pane) and Planner correction 6
  (the browser may select a previously inspected installation candidate, never a path).
- Writer: the single writing agent (Implementer, manual).

## 1. What P3.3 delivers

From the control pane, with an explicit decision for every change:

1. **Prepare** a new version: build the checkout's current commit into a staging installation.
   Refused when the checkout has uncommitted changes (the clean-source guarantee of C-P1.7 E6:
   an installation must name exactly one commit). The pane then shows the candidate: its commit,
   how many database upgrades it would apply, and what will happen.
2. **Install** (first installation) or **Upgrade** to that inspected candidate, after the user
   confirms the summary on the page: back up the database and verify the backup, stop the
   service, apply the candidate's migrations with that backup, activate the candidate, start
   the service, and verify it answers and is ready.
3. **Recover**: after a failed upgrade, the pane shows exactly what happened and offers the
   legal next step: go back to the previous version (only when no migration was applied), or
   restore the verified backup taken before the upgrade and go back to the previous version.
   Restoring an old binary never stands in for reversing a migration.

## 2. Decisions

| # | Decision |
|---|---|
| U1 | **Request kind.** A third kind, `lockstep-install-request 1`, in `requests/<id>.ireq`, through `POST /api/install` (body `<op> <expect>`), signed with the channel key. The C-P3.1 status kind and the C-P3.2 lifecycle kind keep their frozen allowlists. Operations: `prepare-candidate` (expect `candidate-none`, or `candidate-<16 hex>` naming the staged candidate it replaces), `apply-candidate` (expect `candidate-<first 16 hex of the staged binary's SHA-256>`) and `restore-previous` (expect `recovery-<32-hex upgrade id>`). The expectation names the exact candidate or failed upgrade the page showed, so a stale page, a second tab or a replay cannot apply anything else. Install requests share the pane's one-at-a-time rule with lifecycle requests (409). |
| U1a | **Time limits.** `prepare-candidate` and `apply-candidate` may take long (a build, a backup, a migration): their limit is `LOCKSTEP_HELPER_LONG_TIMEOUT` (default 1800 s, 1–7200). The operation continues if the browser is closed; reopening the pane shows its state. |
| U2 | **Staging.** `.local/staging-install` (operator) or `.local/<NAME>-staging-install` (instance), built by `LOCKSTEP_SERVICE_INSTALL_DIR=<staging> scripts/service install`: the existing, frozen install path, with its `VERSION` (commit, dirty, SHA-256). A dirty checkout is refused before building. Preparing again replaces only the staging installation. |
| U3 | **Upgrade steps**, each journaled in `helper/upgrade/<id>/` before it starts and after it ends: (1) verify the candidate's digest equals the expectation; (2) `scripts/db backup` (instance: its own database), then verify the dump (non-empty, `.sha256` matches, `pg_restore --list` reads it); (3) stop the service; (4) `db migrate --backup <dump>` with the candidate binary; (5) activate: the current installation moves to `.local/install.previous`, the candidate becomes `.local/install` (renames in one directory); (6) start; (7) verify readiness `ready` and the health check. |
| U4 | **Failure handling.** Before step 4: nothing changed in the database; the previous installation is restarted if it had been stopped, the result is `failed`, and `upgrade.state` stays `none`. At or after step 4: the result is `failed` with the step, and the upgrade is marked *recovery-needed* (`upgrade.state`, `upgrade.id`, `upgrade.step`); the pane offers `restore-previous`, which stops the service, empties the database's `public` schema and restores the verified backup into it (`scripts/db restore`, digest-checked — `pg_restore --clean` alone would leave the tables a migration added), puts the previous installation back and starts it. The helper never runs the previous binary against a database it has migrated. |
| U4a | **Backups** go to `.local/backups` (operator) or `.local/<NAME>-backups` (instance), so an instance never writes into the operator's backup folder. |
| U4b | **Refusal codes** added: `dirty-checkout`, `database-ahead` (the candidate knows fewer migrations than the database has: no downgrade), plus `state-changed` for a candidate or failed upgrade other than the one named. |
| U5 | **First installation.** With no `.local/install`, `apply-candidate` skips steps 2–3 when the database has no applied migrations (nothing to lose; C-P1.2 permits a migrate without a backup only then) and otherwise behaves as an upgrade. |
| U6 | **Interrupted upgrade.** An upgrade whose journal has a step started and not ended is reported by `status` as `upgrade.state interrupted` with that step; it is then handled as a failure at that step (U4). |
| U7 | **Database ahead.** When `db status` reports an applied migration this installation does not know, the pane says the database belongs to a newer version and offers no Start; an upgrade to a candidate that knows that migration is allowed, a downgrade is not offered. |
| U8 | **Status fields added**: `candidate.present`, `candidate.commit`, `candidate.digest` (16 hex), `candidate.pending` (migrations it would apply), `upgrade.state` (none, recovery-needed, interrupted), `upgrade.id`, `upgrade.step`, `previous.present`. |
| U9 | **Isolation.** An instance stages, backs up, migrates and activates only its own `.local/<NAME>-…` paths and database; the operator's installation and database are never touched by an instance, and the reverse. |

## 3. Verification (frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Foundation/InstallProtocolTest.hs` | unit | encoding vector (`openssl`), the allowlist, the three kinds of expectation and which operation takes which, kinds do not mix, malformed forms |
| `test/integration/Lockstep/InstallHelperTest.hs` + `Support/Install.hs` | integration, real helper/`scripts/service`/`scripts/db` in a throwaway Git checkout, stateful stubs | prepare builds a clean checkout into staging and status shows it; a dirty checkout is refused and nothing is built; a stale expectation is refused; a failing build leaves no candidate; the upgrade's order (backup, verify, stop, migrate with the backup, start) and its result; a different candidate is not applied; **backup cannot be created**; **backup corrupt**; **migration fails** → recovery-needed → restore-previous; **service start fails** after the migration → recovered; recovery names the exact upgrade; **database ahead** → no downgrade, a newer candidate upgrades; **upgrade interrupted** by a helper crash → reported and recoverable; **two upgrades race** → one migration; a first installation of an empty database needs no backup; **an instance beside the operator's installation** touches only its own installation, staging and database; install content in another kind's file is refused |
| `test/integration/Lockstep/InstallPaneTest.hs` | integration, real pane | `/api/install` guard and session; a signed install request; paths, unknown operations and mismatched expectations are 400; install and lifecycle requests share the one-at-a-time rule (409 both ways); the other kinds refuse install names |
| `test/integration/Lockstep/InstallBrowserTest.hs` | integration, headless Chromium | prepare → review → install with the page showing the candidate, the plan and the result; a failed upgrade explained, and recovery (review → restore) from a fresh browser |
| `scripts/lib/check-upgrade` + `scripts/lib/upgrade-smoke-browser` | host, real Docker, real build, backup, migration and restore, instance `p33c` | an older version (a copy of the operator's binary) upgraded to HEAD: a failure after the migration (port held by a squatter) → attention → recovery from the page restores the backup and the old version → the upgrade again succeeds; the operator's installation, service, pane, database and backup folder untouched |

Page wording the tests rely on: `#prepare-candidate`; "A new version is ready to install" and "N
database upgrade(s)"; `#apply-review` → "Lockstep will: back up the database …"; `#apply-candidate`;
"Done: Lockstep was upgraded." (or "installed."); "The upgrade needs your attention";
`#restore-review` → "Lockstep will: … restore the database backup …"; `#restore-previous`; "Done:
the previous version is back."

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| Frozen files (P3.3, P3.2, P3.1) | digests unchanged | §4 |
| P3.3 groups (unit 11, integration 25 incl. 2 browser) | PASSED on the first implementation run | `check-integration.log` |
| `scripts/check --integration` | PASSED all six steps: 735 unit, 278 integration | `check-integration.log` |
| `scripts/lib/check-upgrade` (real Docker, build, backup, migration, restore; instance `p33c`) | 19 PASS, 0 FAIL: schema 5 (`6c2851d`) → failed start after migration → recovery restored schema 5 and the old version → upgrade to HEAD `614f56c` ready; the operator's installation, service, pane, database and backup folder untouched | `check-upgrade-results.txt` |
| Linux clean clone of `614f56c` | PASSED: format, lint, build, unit (735), integration (278) | `linux-clone.log` |

Implementation notes (decisions within the design, recorded here):

- The migration step does not call `scripts/service cli db migrate --backup FILE`: the installed
  CLI runs in a container that cannot see the host's backup path, so the binary's own backup
  check (C-P1.2 E6) would refuse it. The helper runs one fixed `docker run` of the candidate
  binary with only that verified backup mounted read-only at `/backup/<name>`, and passes that
  path, so the binary's own check still applies.
- `apply-candidate` while an earlier upgrade still needs recovery is refused with the code
  `recovery-needed` (an addition to U4b).

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before install and upgrade were implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/InstallProtocolTest.hs` | `8087e2c5a1b0c5c8f5be5906d658b1ec9d0c092df1b9c78fe918021634b211dc` |
| `test/integration/Lockstep/InstallHelperTest.hs` | `c08f995d9a3977eb8b15fb80b80e5ac52ae73ee57d13404bdbb2c01ced7db4a4` |
| `test/integration/Lockstep/InstallPaneTest.hs` | `a3da864153bab8dfa4f1f1f9b12df7e7974acee758dfbdb8a4a53f14273de32d` |
| `test/integration/Lockstep/InstallBrowserTest.hs` | `c0bdd6b5331a0f05810361eb0ecc4e88819cd6090988426baa3180640ccc82f9` |
| `test/integration/Lockstep/Support/Install.hs` | `076cd6e571c4b52d4c8ff7ebb2be1b5960e9e21658732723301b785119201bee` |
| `scripts/lib/check-upgrade` | `c59daee7384b326e28897d34f703861b53838bab79ff919c10882fea5cf46083` |
| `scripts/lib/upgrade-smoke-browser` | `98afb115fc14effbb5029e62c536d7e2f1b8a27969a7cd367e78a5dfe3ff3c74` |
| `test/unit/Main.hs` (runner, additive) | `4fee2cc397da5f67144d7c3852fdd9bb5bc315d4b2d439788032493c18fecb6f` |
| `test/integration/Main.hs` (runner, additive) | `bf20ccc9bb3eb6f5f2ee4a6a0a0aa92e555b35cf53cbdc9a9a981efe54cab3ca` |

The C-P3.1 and C-P3.2 frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- Unit baseline against type-only stubs (`prefreeze-unit-baseline.log`): 7 of 735 fail, all new;
  four new cases pass against the stub (refusals a refusing stub meets, kinds not mixing, and the
  HMAC vector through the C-P3.1 `hmacHex`). The codec was then implemented before the freeze, as
  in C-P3.1 and C-P3.2, because the fixtures encode requests through it: all 11 pass.
- Integration fixtures against the C-P3.2 helper and pane (`prefreeze-integration-baseline.log`):
  23 of 25 fail, each on its behaviour (no install result, 404 for `/api/install`, no Prepare
  button); the Git checkout, stubs and helper start were exercised. Two pass: install content in
  a lifecycle file refused as malformed, and the other kinds refusing install names (C-P3.1 and
  C-P3.2 behaviour).
- Design defects found while writing the tests and fixed in the contract before the freeze: a
  plain `pg_restore --clean` would keep tables a migration added (U4 now empties the schema
  first); instance backups would have gone into the operator's backup folder (U4a).
- Not exercised before the freeze: `scripts/lib/check-upgrade` needs a clean checkout (an upgrade
  builds the committed HEAD), so it was only syntax-checked (`bash -n`); it first runs after the
  implementation commit.
