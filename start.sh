#!/bin/sh
set -e
cd /workspace

# any args given to `docker run` (with --entrypoint reset) are executed as-is
if [ $# -gt 0 ]; then exec "$@"; fi

: "${JUPYTER_IP:=0.0.0.0}"
: "${JUPYTER_PORT:=8888}"
: "${JUPYTER_TOKEN:=}"

# A `start` task in the pixi environment wins if it exists.
if pixi task list -e "$PIXI_ENVIRONMENT" 2>/dev/null | awk '{print $1}' | grep -qx start; then
    exec pixi run -e "$PIXI_ENVIRONMENT" start
fi

exec pixi run -e "$PIXI_ENVIRONMENT" jupyter lab \
    --ip="$JUPYTER_IP" \
    --port="$JUPYTER_PORT" \
    --allow-root \
    --no-browser \
    --ServerApp.token="$JUPYTER_TOKEN" \
    --ServerApp.root_dir=/workspace
