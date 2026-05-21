#!/usr/bin/env bash
# Re-render every diagram source file in this directory to PNG (and SVG).
#
# Usage:
#   ./render.sh                 # plain render
#   ./render.sh --sketch        # hand-drawn / xkcd style (Graphviz + d2 only)
#   ./render.sh <any swgraph flag>...
#
# Env overrides:
#   SWGRAPH_IMAGE   container image (default: mpagot/swgraph)
#   CONTAINER_CMD   podman | docker (default: auto-detect)
#
# Source files are auto-discovered. SVGs are emitted alongside PNGs and are
# gitignored; only sources + PNGs are checked in.

set -euo pipefail

cd "$(dirname "$0")"

SWGRAPH_IMAGE="${SWGRAPH_IMAGE:-mpagot/swgraph}"

if [[ -z "${CONTAINER_CMD:-}" ]]; then
    if command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD=podman
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD=docker
    else
        echo "render.sh: neither podman nor docker found in PATH" >&2
        exit 1
    fi
fi

shopt -s nullglob
sources=( *.gv *.d2 *.puml *.mmd *.dsl *.ditaa )
shopt -u nullglob

if [[ ${#sources[@]} -eq 0 ]]; then
    echo "render.sh: no diagram sources found in $(pwd)" >&2
    exit 1
fi

echo "render.sh: rendering ${#sources[@]} source(s) via ${CONTAINER_CMD} ${SWGRAPH_IMAGE}"

"$CONTAINER_CMD" run --rm \
    -v "$PWD:/work:Z" \
    -v "$PWD:/output:Z" \
    -w /work \
    "$SWGRAPH_IMAGE" \
    swgraph render "$@" "${sources[@]}"
