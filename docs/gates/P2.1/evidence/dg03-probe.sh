#!/usr/bin/env bash
# DG-03 evidence probe: how Git reports identity for worktrees, symlinks,
# case variants, subdirectories, clones and shallow clones.
# Usage: dg03-probe.sh <empty scratch directory>
set -euo pipefail
S=$(cd "$1" && pwd -P)
cd "$S"
git -c init.defaultBranch=main init -q orig
git -C orig -c user.name=t -c user.email=t@x commit -q --allow-empty -m root
git -C orig -c user.name=t -c user.email=t@x commit -q --allow-empty -m second
git -C orig remote add origin git@GitHub.com:Owner/Repo.git
git -C orig worktree add -q ../wt -b feature
ln -s orig link
git clone -q orig clone
git clone -q --depth 1 "file://$S/orig" shallow
mkdir orig/sub
echo "== git-common-dir | show-toplevel | is-shallow, per spelling (\$S = scratch dir)"
for p in orig wt link ORIG orig/sub clone shallow; do
  printf '%-9s ' "$p"
  git -C "$p" rev-parse --path-format=absolute --git-common-dir --show-toplevel --is-shallow-repository \
    | sed "s#$S#\$S#g" | tr '\n' ' '
  echo
done
echo "== python os.path.realpath('\$S/ORIG') (does it normalise case?)"
python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$S/ORIG" | sed "s#$S#\$S#g"
echo "== device inode of .git"
for p in orig ORIG link clone; do stat -f "%d %i $p/.git" "$p/.git"; done
echo "== root commits"
for p in orig clone shallow; do printf '%-8s ' "$p"; git -C "$p" rev-list --max-parents=0 HEAD | tr '\n' ' '; echo; done
echo "== remote URL as configured, and with an insteadOf rewrite"
git -C orig remote get-url origin
git -C clone remote get-url origin | sed "s#$S#\$S#g"
git -C orig -c url."https://github.com/".insteadOf=git@GitHub.com: ls-remote --get-url origin
