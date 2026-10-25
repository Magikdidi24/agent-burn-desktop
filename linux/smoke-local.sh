#!/usr/bin/env bash
# Smoke test of one distro on a dev workstation, with podman: linux/smoke.sh in IMAGE (repo mounted read-only).
#   linux/smoke-local.sh IMAGE [DIST]
#   e.g.: smoke-local.sh docker.io/library/debian:13; DIST = dist/linux by default
# Logs and captures in DIST/smoke-<distro>-<version>/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${1:?usage: smoke-local.sh IMAGE [DIST]}
DIST=$(cd "${2:-$REPO/dist/linux}" && pwd)
exec podman run --rm --pull=newer --security-opt label=disable -v "$REPO:/src:ro" -v "$DIST:/dist" \
    "$IMAGE" bash /src/linux/smoke.sh /dist
