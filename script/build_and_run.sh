#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Compatibility entrypoint for callers at the repository root. The SwiftPM
# package script owns the single build output, bundle, signing, and launch path.
exec "$ROOT_DIR/NetVplayer/script/build_and_run.sh" "$@"
