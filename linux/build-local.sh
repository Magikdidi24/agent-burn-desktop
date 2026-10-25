#!/usr/bin/env bash
# Build Linux sur un poste de dev : linux/build.sh dans la même image que la CI, avec podman (sans root).
#   desktop/agent-burn/linux/build-local.sh          SKIP_CLI=1 … : réutilise build/cli-linux
# Caches cargo, rustup et pip gardés d'un build à l'autre dans AB_CACHE : un volume podman
# (agent-burn-build-cache par défaut) ou un dossier absolu. Sorties : desktop/agent-burn/dist/linux/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# label=disable : sous SELinux (Fedora), le conteneur ne lirait pas le dépôt monté sans réétiqueter ses fichiers.
exec podman run --rm --pull=newer --security-opt label=disable \
    -v "$REPO:/src" -v "${AB_CACHE:-agent-burn-build-cache}:/cache" \
    -e CARGO_HOME=/cache/cargo -e RUSTUP_HOME=/cache/rustup -e PIP_CACHE_DIR=/cache/pip -e SKIP_CLI="${SKIP_CLI:-}" \
    docker.io/library/python:3.12-slim-bookworm bash /src/desktop/agent-burn/linux/build.sh
