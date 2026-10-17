# Lockstep development and build container (canonical build environment).
#
# Derived from Launchpad 11886bf's Dockerfile. Removed relative to Launchpad:
# openssh-client and any SSH key mount (every dependency is public).
#
# The host needs only Docker; GHC, Stack, fourmolu and hlint live here.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

ENV BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_GHC_VERSION=9.10.3 \
    BOOTSTRAP_HASKELL_CABAL_VERSION=3.14.2.0 \
    BOOTSTRAP_HASKELL_INSTALL_STACK=1 \
    BOOTSTRAP_HASKELL_STACK_VERSION=3.7.1 \
    BOOTSTRAP_HASKELL_INSTALL_NO_STACK_HOOK=1 \
    PATH=/root/.ghcup/bin:/root/.cabal/bin:/root/.local/bin:$PATH

RUN apt-get update \
      && apt-get install -y --no-install-recommends \
           build-essential \
           ca-certificates \
           curl \
           git \
           iproute2 \
           libffi-dev \
           libgmp-dev \
           libnuma-dev \
           libtinfo-dev \
           pkg-config \
           xz-utils \
           zlib1g-dev \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/* \
      && curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org -o /tmp/ghcup-install.sh \
      && sh /tmp/ghcup-install.sh \
      && rm /tmp/ghcup-install.sh

ENV LANG=C.UTF-8 \
    TZ=UTC

RUN cabal update \
      && cabal install \
           fourmolu-0.18.0.0 \
           hlint-3.10 \
           --installdir=/usr/local/bin \
           --install-method=copy \
           --overwrite-policy=always \
      && fourmolu --version \
      && hlint --version \
      && ghc --numeric-version \
      && stack --numeric-version

# C++ libraries for the libphonenumber Haskell binding, which Brigid requires.
RUN apt-get update \
      && apt-get install -y --no-install-recommends \
           libphonenumber-dev \
           libprotobuf-dev \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*

# The project stack.yaml sets system-ghc/install-ghc so Stack uses this GHC.
ENV STACK_ROOT=/stack-root
WORKDIR /work
