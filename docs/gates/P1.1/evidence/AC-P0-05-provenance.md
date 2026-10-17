# AC-P0-05 — Launchpad archive equals the private repository commit (pre-import gate)

- Captured: 2026-10-17T02:15Z, manual agent session (no v2 Supervisor)
- Lockstep basis: branch `v2` at `a97bd0ce3aaf1f0947561aab7a6238321885dbfa`, clean
- Disposition: **PASSED** — performed before any Launchpad file entered `v2`
- Tools: git 2.50.1 (Apple Git-155), OpenSSH_10.3p1, macOS Darwin 25.6

## Identities

| Item | Value |
|---|---|
| Archive | `.local/launchpad-main.zip`, SHA-256 `696147a423d0075980d35347e45f50160223ac3d07aaf4279c5e12969481efca` (matches SOURCE_REGISTER / Audit §1) |
| Repository | `git@github.com:AugmenTab/launchpad.git` (private), authenticated with the operator's existing SSH key, `BatchMode=yes` (no prompt, no token in chat) |
| Remote refs | `HEAD` and `refs/heads/main` → `11886bf73c2e3ac69a6839af28b97ba79bbee5fb` |
| Commit | `11886bf73c2e3ac69a6839af28b97ba79bbee5fb`, author AugmenTab, 2026-09-12T19:25:09-05:00, "Adds progressive disclosure agent files" |
| Commit tree | `2d3f3d7caf7bacfe315e914fabba47a61054d150` |
| Git tree recomputed from archive contents | `2d3f3d7caf7bacfe315e914fabba47a61054d150` — **identical** |
| Files | 201 in archive, 201 in commit (186 mode 100644, 15 mode 100755, 0 symlinks) |
| Byte diff (`diff -r`) | empty, exit 0 |

Because the recomputed Git tree object hash is equal, file names, contents and
executable modes are all identical. The archive comment was not relied on.

## Commands (cwd `.local/provenance/`, which is gitignored)

```sh
GIT_SSH_COMMAND="ssh -o BatchMode=yes" git ls-remote git@github.com:AugmenTab/launchpad.git
GIT_SSH_COMMAND="ssh -o BatchMode=yes" git clone --bare --quiet git@github.com:AugmenTab/launchpad.git launchpad.git
git -C launchpad.git rev-parse '11886bf73c2e3ac69a6839af28b97ba79bbee5fb^{tree}'   # 2d3f3d7c…
unzip -q ../launchpad-main.zip -d zip
git -C launchpad.git archive --format=tar 11886bf73c2e3ac69a6839af28b97ba79bbee5fb | tar -x -C repo
diff -r zip/launchpad-main repo                                                   # exit 0, no output
git init -q --bare ziptree.git
GIT_DIR=ziptree.git GIT_WORK_TREE=zip/launchpad-main git add -A -f
GIT_DIR=ziptree.git git write-tree                                               # 2d3f3d7c…
```

The bare clone stays in `.local/provenance/launchpad.git` (not committed). Nothing
was pushed to either repository.
