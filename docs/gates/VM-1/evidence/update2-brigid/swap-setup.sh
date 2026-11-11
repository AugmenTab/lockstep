# Brigid capsules: a 16 GiB swap file (Phase 5 update 2 §6.2). GHC compiling Brigid's larger modules in
# parallel (its package sets -j) exceeded the large profile's 12 GiB without swap. Idempotent; persists in
# /etc/fstab, so it survives restarts, snapshots and restores.
set -e
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  [ -f /swapfile ] || { sudo fallocate -l 16G /swapfile; sudo chmod 600 /swapfile; sudo mkswap /swapfile > /dev/null; }
  sudo swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
free -g
