#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/artifacts/visual-regression/player-hud}"
INSTALL_DIR="/Applications"
APP_BINARY="$INSTALL_DIR/NetVplayer.app/Contents/MacOS/NetVplayerApp"
FIXTURE_PATH="$ROOT_DIR/docs/design/player-ui/assets/w700d1q75cms.jpg"
STATES=(normal settings-drawer episode-drawer skip-dialog warning error loading buffering hud-hidden)
VIEWPORTS=(1480x833 1200x675)

mkdir -p "$OUTPUT_DIR"

first_capture=true
for viewport in "${VIEWPORTS[@]}"; do
  for state in "${STATES[@]}"; do
    output_path="$OUTPUT_DIR/player-hud-$state-$viewport.png"
    if [[ "$first_capture" == true ]]; then
      "$ROOT_DIR/script/build_and_run.sh" --capture-player-hud "$output_path" "$state" "$viewport"
      first_capture=false
    else
      "$APP_BINARY" \
        --visual-regression-player "$state" \
        --visual-regression-fixture "$FIXTURE_PATH" \
        --visual-regression-viewport "$viewport" \
        --visual-regression-output "$output_path"
    fi
  done
done

echo "Captured ${#STATES[@]} player states across ${#VIEWPORTS[@]} viewports in $OUTPUT_DIR"
