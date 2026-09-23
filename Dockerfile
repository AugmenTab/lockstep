# syntax=docker/dockerfile:1.7
#
# Lockstep application runtime image.
#
# Two stages:
#   1. build   — installs the dev extra, runs ./scripts/check (the canonical
#                repository health contract), and builds a wheel of the
#                project plus its runtime dependencies.
#   2. runtime — installs only those wheels into a slim image, drops to a
#                non-root user, and exposes `lockstep` as the entrypoint.

# ---------------------------------------------------------------------------
# Stage 1: verification and wheel build
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /workspace

COPY . .

RUN python -m pip install ".[dev]"

RUN ./scripts/check

RUN python -m pip wheel --wheel-dir /wheels .

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system --gid 1001 lockstep \
 && useradd  --system --uid 1001 --gid lockstep \
             --home-dir /home/lockstep --create-home \
             --shell /usr/sbin/nologin lockstep

COPY --from=build /wheels /tmp/wheels
RUN python -m pip install --no-index --find-links=/tmp/wheels lockstep \
 && rm -rf /tmp/wheels

USER lockstep
WORKDIR /home/lockstep

ENTRYPOINT ["lockstep"]
