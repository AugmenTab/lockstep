# Brigid verification capsule: trusted toolchain setup (Phase 5 update 2 §6.3). Run by the operator
# through `capsule-runtime run`, never by a model. Only the project's normal mechanisms: Ubuntu packages
# for the C libraries its Dockerfile installs, the official Stack installer, and Stack's own GHC setup
# for the resolver in stack-ghc-9.10.yaml (the file scripts/test uses).
set -e
echo "== setup start $(date -u +%FT%TZ)"
# NEEDRESTART_SUSPEND: Ubuntu's needrestart would otherwise restart sshd mid-script and end this session.
sudo NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends \
  libphonenumber-dev libprotobuf-dev libgmp-dev zlib1g-dev libtinfo-dev libffi-dev pkg-config curl ca-certificates xz-utils > /dev/null
if ! command -v stack > /dev/null; then
  curl -sSL https://get.haskellstack.org/ -o /tmp/install-stack.sh
  sh /tmp/install-stack.sh > /tmp/install-stack.log 2>&1 || { tail -n 20 /tmp/install-stack.log; exit 1; }
fi
stack --version
cd /work/tree
stack --stack-yaml stack-ghc-9.10.yaml setup > /tmp/stack-setup.log 2>&1 || { tail -n 30 /tmp/stack-setup.log; exit 1; }
stack --stack-yaml stack-ghc-9.10.yaml exec -- ghc --version
echo "== setup done $(date -u +%FT%TZ)"
