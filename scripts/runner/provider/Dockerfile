# The provider image (contract C-P4.L L1, L2): the pinned Claude Code CLI for
# the live role runs, and the egress proxy, built from the same pinned Debian
# as the dev image. Built by scripts/provider-image; the helper runs it only
# for run-live-readonly and run-live-write (the role's container, no network
# but the proxy's, the CLI and its tools as two identities) and for the proxy
# itself. Nothing here holds a credential.
#
# The CLI is the platform package of @anthropic-ai/claude-code 2.1.312, its
# npm tarball checked against the registry's published SHA-512 integrity
# before it is unpacked. Claude Code is Anthropic's proprietary software; this
# image is built and used locally only and is never published.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS download

ARG TARGETARCH
RUN apt-get update \
      && apt-get install -y --no-install-recommends ca-certificates curl openssl \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "$TARGETARCH" in \
      arm64) platform=linux-arm64; integrity=sha512-2BYrAYcr5q9mG/7qD8NN8Mnh8YLvW1cj6O9WjLXHh4OoraA+vjwAYkP7dMyGXQ/nQW/ydw483j8G91dmsMBXPA== ;; \
      amd64) platform=linux-x64; integrity=sha512-oj55HL9uasLWzym5eZNgC8xyk0N0H4hw8WdN0DeDuAlquhs2d4hhkQVZcRKvJarBB37IU9bbEGXZwtuhsex6EQ== ;; \
      *) echo "unsupported architecture $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -fsSL -o /tmp/cli.tgz \
      "https://registry.npmjs.org/@anthropic-ai/claude-code-$platform/-/claude-code-$platform-2.1.312.tgz"; \
    got="sha512-$(openssl dgst -sha512 -binary /tmp/cli.tgz | base64 -w 0)"; \
    [ "$got" = "$integrity" ] || { echo "integrity mismatch: $got" >&2; exit 1; }; \
    tar -xzf /tmp/cli.tgz -C /tmp package/claude; \
    install -m 0755 /tmp/package/claude /usr/local/bin/claude

FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
      && apt-get install -y --no-install-recommends ca-certificates git python3 \
      && apt-get clean \
      && rm -rf /var/lib/apt/lists/*
COPY --from=download /usr/local/bin/claude /usr/local/bin/claude
COPY egress-proxy /opt/lockstep/egress-proxy
# The two identities of a live role's container (contract C-P4.L.R3): the CLI's
# start, and the shell prefix that runs each tool call as the host's user.
COPY agent-entry tool-shell /opt/lockstep/
ENV LANG=C.UTF-8 \
    TZ=UTC
