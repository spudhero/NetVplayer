#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"

# Compatibility entrypoint for callers at the repository root. The SwiftPM
# package script owns the single build output, bundle, signing, and launch path.
exec "$ROOT_DIR/NetVplayer/script/build_and_run.sh" "$@"
