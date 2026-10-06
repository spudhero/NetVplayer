#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Credential files are parsed as literal assignments, never sourced as shell code.
# --save-file is offline; --refresh sends the API Key only to the official endpoint.
if [[ "$#" -eq 0 && -z "${NETVPLAYER_XUNLEI_API_KEY:-}" && ! -f "$HOME/.config/netvplayer/thunder.env" ]]; then
  exec python3 "$SCRIPT_DIR/xunlei_credentials.py" --save-key --refresh
fi
exec python3 "$SCRIPT_DIR/xunlei_credentials.py" "$@"
