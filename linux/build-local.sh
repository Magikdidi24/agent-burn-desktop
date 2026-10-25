#!/usr/bin/env bash
# Build Linux sur un poste de dev : linux/build.sh dans la même image que la CI, avec podman (sans root).
#   desktop/agent-burn/linux/build-local.sh          SKIP_CLI=1 … : réutilise build/cli-linux
# Caches cargo, rustup et pip gardés d'un build à l'autre dans AB_CACHE : un volume podman
# (agent-burn-build-cache par défaut) ou un dossier absolu. Sorties : desktop/agent-burn/dist/linux/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# label=disable : sous SELinux (Fedora), le conteneur ne lirait pas le dépôt monté sans réétiqueter ses fichiers.
# Image épinglée par empreinte, la même que la CI (.github/workflows/agent-burn-desktop.yml).
# GITHUB_SHA : commit lu ici, build.sh s'y replie ; dans un worktree, le .git monté pointe hors du conteneur.
exec podman run --rm --pull=missing --security-opt label=disable \
    -v "$REPO:/src" -v "${AB_CACHE:-agent-burn-build-cache}:/cache" \
    -e CARGO_HOME=/cache/cargo -e RUSTUP_HOME=/cache/rustup -e PIP_CACHE_DIR=/cache/pip -e SKIP_CLI="${SKIP_CLI:-}" \
    -e GITHUB_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" \
    docker.io/library/python:3.12-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70 \
    bash /src/desktop/agent-burn/linux/build.sh
