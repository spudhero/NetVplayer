#!/bin/bash
set -euo pipefail
SDK_VERSION="1.0.3"
SDK_ARCHIVE_SHA256="0e42b22d370b6d6e36580b1b6e9ad0faa52767b5ae0ac2a8b3b7aca20b424d2a"
SDK_LIBRARY_SHA256="b4215fedabffd3bf65d0707725806b041b38dc34f4a88cfa15490872dfc3189f"
SDK_DIRECTORY="${NETVPLAYER_XUNLEI_SDK_DIR:-$HOME/Library/Application Support/NetVplayer/ThunderDownloadSDK}"
SDK_TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/netvplayer-xunlei-sdk.XXXXXX")"
trap 'rm -rf "$SDK_TEMPORARY"' EXIT
if [[ -n "${NETVPLAYER_XUNLEI_SDK_ARCHIVE:-}" ]]; then
  cp "$NETVPLAYER_XUNLEI_SDK_ARCHIVE" "$SDK_TEMPORARY/sdk.zip"
else
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 120 --retry 2 \
    "https://github.com/xunlei-open/xunlei-dlsdk/releases/download/v$SDK_VERSION/xunlei-dlsdk-swift-$SDK_VERSION.zip" \
    --output "$SDK_TEMPORARY/sdk.zip"
fi
if [[ "$(shasum -a 256 "$SDK_TEMPORARY/sdk.zip" | awk '{print $1}')" != "$SDK_ARCHIVE_SHA256" ]]; then
  echo "error: official SDK archive hash mismatch" >&2; exit 1
fi
unzip -q "$SDK_TEMPORARY/sdk.zip" -d "$SDK_TEMPORARY/unpacked"
SDK_LIBRARY="$SDK_TEMPORARY/unpacked/xunlei-dlsdk-swift/Binaries/macos/libdk.dylib"
if [[ ! -f "$SDK_LIBRARY" || "$(shasum -a 256 "$SDK_LIBRARY" | awk '{print $1}')" != "$SDK_LIBRARY_SHA256" ]]; then
  echo "error: official macOS SDK library hash mismatch" >&2; exit 1
fi
/usr/bin/lipo "$SDK_LIBRARY" -verify_arch arm64 x86_64
if [[ -e "$SDK_DIRECTORY/libdk.dylib" && "$(shasum -a 256 "$SDK_DIRECTORY/libdk.dylib" | awk '{print $1}')" != "$SDK_LIBRARY_SHA256" ]]; then
  echo "error: existing SDK differs; replacement requires an explicit upgrade" >&2; exit 1
fi
mkdir -p "$SDK_DIRECTORY"
install -m 755 "$SDK_LIBRARY" "$SDK_DIRECTORY/libdk.dylib"
echo "Installed official Xunlei Swift SDK $SDK_VERSION (Universal)."
