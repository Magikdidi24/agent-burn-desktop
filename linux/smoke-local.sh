#!/usr/bin/env bash
# Smoke test d'une distro sur un poste de dev, avec podman : linux/smoke.sh dans IMAGE (dépôt en lecture seule).
#   desktop/agent-burn/linux/smoke-local.sh IMAGE [DIST]
#   ex. : smoke-local.sh docker.io/library/debian:13 ; DIST = desktop/agent-burn/dist/linux par défaut
# Journaux et captures dans DIST/smoke-<distro>-<version>/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
IMAGE=${1:?usage : smoke-local.sh IMAGE [DIST]}
DIST=$(cd "${2:-$REPO/desktop/agent-burn/dist/linux}" && pwd)
exec podman run --rm --pull=newer --security-opt label=disable -v "$REPO:/src:ro" -v "$DIST:/dist" \
    "$IMAGE" bash /src/desktop/agent-burn/linux/smoke.sh /dist
