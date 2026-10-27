#!/bin/sh
set -e
cd "$(dirname "$0")"

IMAGE="${IMAGE:-jupyter-amd64:latest}"

docker build --provenance=false -t "$IMAGE" \
    ${PIXI_ENVIRONMENT:+--build-arg PIXI_ENVIRONMENT="$PIXI_ENVIRONMENT"} .

# notebooks/persist state in ./work (mounted at /workspace/work)
mkdir -p work
exec docker run --rm -it \
    -p "${JUPYTER_PORT:-8888}:8888" \
    -v "$PWD/work:/workspace/work" \
    -e JUPYTER_TOKEN="${JUPYTER_TOKEN:-}" \
    "$IMAGE"
