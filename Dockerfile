# syntax=docker/dockerfile:1
# =====================================================================
# linux/amd64 Jupyter Lab image for Apple Silicon (Rosetta emulation),
# driven entirely by your Pixi files (pixi.toml and/or pyproject.toml,
# plus pixi.lock if you have one).
#
# Ships /opt/rossetafix/libnosigtrap.so, an LD_PRELOAD shim that fixes
# the Rosetta 2 fork() deadlock (macOS 26.1+) that otherwise prevents
# every ZMQ-based Jupyter kernel from starting under emulation.
# See nosigtrap.c + README.md for the root cause.
# =====================================================================

# ---- Stage 1: cross-compile the fix for x86_64 (runs at NATIVE arm64
#      speed, so no emulated compiler is needed) --------------------
FROM debian:bookworm-slim AS rosetta-fix
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc-x86-64-linux-gnu libc6-dev-amd64-cross \
 && rm -rf /var/lib/apt/lists/*
COPY nosigtrap.c /src/nosigtrap.c
RUN x86_64-linux-gnu-gcc -O2 -fPIC -shared -o /libnosigtrap.so /src/nosigtrap.c -ldl

# pixi, pinned to amd64 (without --platform, buildx resolves it to the
# host arch and pixi then refuses a linux-64 workspace)
FROM --platform=linux/amd64 ghcr.io/prefix-dev/pixi:latest AS pixi

# ---- Stage 2: amd64 runtime with pixi ------------------------------
FROM --platform=linux/amd64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git openssh-client \
 && rm -rf /var/lib/apt/lists/*

COPY --from=pixi /usr/local/bin/pixi /usr/local/bin/pixi

# the Rosetta fork() fix, applied to every process in the container
COPY --from=rosetta-fix /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so

# which pixi environment to install/serve (build arg AND runtime env)
ARG PIXI_ENVIRONMENT=default
ENV PIXI_ENVIRONMENT=${PIXI_ENVIRONMENT}

WORKDIR /workspace
# your pixi files (and notebooks) come in with the build context
COPY . /workspace
RUN chmod +x /workspace/start.sh \
 && if [ -f pixi.lock ]; then pixi install --frozen -e "$PIXI_ENVIRONMENT"; else pixi install -e "$PIXI_ENVIRONMENT"; fi

EXPOSE 8888
# if pixi.toml defines a `start` task it is used; otherwise plain
# `jupyter lab` is launched from the environment.
ENTRYPOINT ["/workspace/start.sh"]
