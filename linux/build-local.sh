#!/usr/bin/env bash
# Linux build on a dev workstation: linux/build.sh in the same image as CI, with podman (rootless).
#   linux/build-local.sh          SKIP_CLI=1 …: reuses build/cli-linux
# cargo, rustup and pip caches kept from one build to the next in AB_CACHE: a podman volume
# (agent-burn-build-cache by default) or an absolute directory. Outputs: dist/linux/.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# label=disable: under SELinux (Fedora), the container could not read the mounted repo without relabeling its files.
# Image pinned by digest, the same as CI (.github/workflows/ci.yml).
# GITHUB_SHA: commit read here, build.sh falls back to it; in a worktree, the mounted .git points outside the container.
exec podman run --rm --pull=missing --security-opt label=disable \
    -v "$REPO:/src" -v "${AB_CACHE:-agent-burn-build-cache}:/cache" \
    -e CARGO_HOME=/cache/cargo -e RUSTUP_HOME=/cache/rustup -e PIP_CACHE_DIR=/cache/pip -e SKIP_CLI="${SKIP_CLI:-}" \
    -e GITHUB_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" \
    docker.io/library/python:3.12-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70 \
    bash /src/linux/build.sh
