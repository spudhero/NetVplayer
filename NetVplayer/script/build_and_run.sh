#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NetVplayerApp"
BUNDLE_NAME="NetVplayer"
BUNDLE_ID="com.netvplayer.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT_DIR/Sources/NetVplayerApp/Info.plist")"
APP_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$ROOT_DIR/Sources/NetVplayerApp/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: CFBundleShortVersionString must use MAJOR.MINOR.PATCH" >&2
  exit 1
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CFBundleVersion must be a positive integer" >&2
  exit 1
fi
INSTALL_DIR="/Applications"
PACKAGE_PUBLIC=false
if [[ "$MODE" == "--package-public" ]]; then
  PACKAGE_PUBLIC=true
  if [[ "${2:-}" != /* || "$2" == "/Applications" ]]; then
    echo "error: --package-public requires an absolute output directory outside /Applications" >&2
    exit 2
  fi
  INSTALL_DIR="$2"
  if [[ -e "$INSTALL_DIR/$BUNDLE_NAME.app" ]]; then
    echo "error: public package output already exists" >&2
    exit 2
  fi
  python3 "$REPOSITORY_ROOT/script/audit_source_free_app.py" \
    --repo "$REPOSITORY_ROOT" --output-directory "$INSTALL_DIR"
fi
APP_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME.app"
STAGING_APP_BUNDLE="$INSTALL_DIR/.$BUNDLE_NAME.app.staging.$$"
PREVIOUS_APP_BUNDLE="$INSTALL_DIR/.$BUNDLE_NAME.app.previous.$$"
OBSOLETE_APP_BUNDLES=(
  "$ROOT_DIR/dist/$BUNDLE_NAME.app"
  "$REPOSITORY_ROOT/dist/$BUNDLE_NAME.app"
)
APP_CONTENTS="$STAGING_APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INSTALLED_APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PROVIDER_MANIFEST_PUBLIC_KEY="${NETVPLAYER_PROVIDER_MANIFEST_PUBLIC_KEY_BASE64:-}"
PROVIDER_DISTRIBUTION_PUBLIC_KEY="${NETVPLAYER_PROVIDER_DISTRIBUTION_PUBLIC_KEY_BASE64:-}"
PROVIDER_DISTRIBUTION_INDEX_URL="${NETVPLAYER_PROVIDER_DISTRIBUTION_INDEX_URL:-}"
if [[ "$PACKAGE_PUBLIC" == true && -z "$PROVIDER_MANIFEST_PUBLIC_KEY$PROVIDER_DISTRIBUTION_PUBLIC_KEY$PROVIDER_DISTRIBUTION_INDEX_URL" ]]; then
  RELEASE_TRUST_FILE="$REPOSITORY_ROOT/provider-sdk/release-trust.json"
  PROVIDER_MANIFEST_PUBLIC_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest_public_key"])' "$RELEASE_TRUST_FILE")"
  PROVIDER_DISTRIBUTION_PUBLIC_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["distribution_public_key"])' "$RELEASE_TRUST_FILE")"
  PROVIDER_DISTRIBUTION_INDEX_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["index_url"])' "$RELEASE_TRUST_FILE")"
fi
LOG_FILE="/tmp/NetVplayer.log"
APP_DIAGNOSTIC_LOG="$HOME/Library/Logs/NetVplayer/current.log"
APP_ICON_NAME="AppIcon"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon-Source.png"
APP_ICON_COMPOSER_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME.icon"
APP_ICON_COMPOSER_ARTWORK="$APP_ICON_COMPOSER_SOURCE/Assets/AppIcon-Source.png"
APP_ICON_COMPOSER_JSON="$APP_ICON_COMPOSER_SOURCE/icon.json"
LEGACY_APP_ICON_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME.icns"
APP_ICON_PARTIAL_INFO="$APP_CONTENTS/AppIconPartialInfo.plist"
APP_RESOURCE_BUNDLE_NAME="NetVplayer_NetVplayerApp.bundle"
TORRENT_BRIDGE_SOURCE="$ROOT_DIR/Resources/TorrentBridge"
TORRENT_BRIDGE_DESTINATION="$APP_RESOURCES/TorrentBridge"
NODE_RUNTIME_LOCK="$REPOSITORY_ROOT/provider-runners/runtime-lock-v1.json"
NODE_RUNTIME_CACHE="${NETVPLAYER_NODE_RUNTIME_CACHE:-/tmp/netvplayer-node-runtime-cache}"
PREPARED_NODE_RUNTIME_ROOT="/tmp/NetVplayer-NodeRuntime.$$"
PREPARED_NODE_EXECUTABLE="$PREPARED_NODE_RUNTIME_ROOT/bin/node"
PREPARED_NODE_NPM_ROOT="/tmp/NetVplayer-NodeBuildTools.$$/npm"
NPM_CLI_PATH="$PREPARED_NODE_NPM_ROOT/bin/npm-cli.js"
BUNDLED_NODE_RUNTIME_ROOT="$APP_RESOURCES/NodeRuntime"
BUNDLED_NODE_EXECUTABLE="$BUNDLED_NODE_RUNTIME_ROOT/bin/node"
QUICKJS_RUNTIME_LOCK="$REPOSITORY_ROOT/provider-runners/quickjs-runtime-lock-v1.json"
QUICKJS_RUNTIME_CACHE="${NETVPLAYER_QUICKJS_RUNTIME_CACHE:-/tmp/netvplayer-quickjs-runtime-cache}"
PREPARED_QUICKJS_RUNTIME_ROOT="/tmp/NetVplayer-QuickJSRuntime.$$"
PREPARED_QUICKJS_EXECUTABLE="$PREPARED_QUICKJS_RUNTIME_ROOT/bin/qjs"
BUNDLED_QUICKJS_RUNTIME_ROOT="$APP_RESOURCES/QuickJSRuntime"
BUNDLED_QUICKJS_EXECUTABLE="$BUNDLED_QUICKJS_RUNTIME_ROOT/bin/qjs"
BUNDLED_QUICKJS_POLYGLOT="$BUNDLED_QUICKJS_RUNTIME_ROOT/bin/qjs-cosmo"
BUNDLED_QUICKJS_BOOTSTRAP="$BUNDLED_QUICKJS_RUNTIME_ROOT/bin/.ape-1.10"
RUN_LOCK_FILE="/tmp/$APP_NAME.build-and-run.lock"
if [[ "$PACKAGE_PUBLIC" == true ]]; then
  RUN_LOCK_FILE="/tmp/$APP_NAME.public-package.$$.lock"
fi
RUN_LOCK_HELD=false
LSREGISTER_PATH="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -f "$APP_ICON_SOURCE" || ! -f "$APP_ICON_COMPOSER_JSON" || ! -f "$APP_ICON_COMPOSER_ARTWORK" ]]; then
  echo "error: modern app icon source is incomplete at $APP_ICON_COMPOSER_SOURCE" >&2
  exit 1
fi
if [[ ! -f "$LEGACY_APP_ICON_SOURCE" ]]; then
  echo "error: legacy app icon not found at $LEGACY_APP_ICON_SOURCE" >&2
  exit 1
fi
if ! cmp -s "$APP_ICON_SOURCE" "$APP_ICON_COMPOSER_ARTWORK"; then
  echo "error: $APP_ICON_COMPOSER_ARTWORK must match $APP_ICON_SOURCE" >&2
  exit 1
fi

# Keep the artwork source unmodified. The modern group uses the smallest
# verified scale that covers the static system canvas while preserving the
# metallic frame; the Dock still loads the untouched source PNG at runtime.
if ! APP_ICON_FILL="$(plutil -extract fill.solid raw "$APP_ICON_COMPOSER_JSON" 2>/dev/null)" \
  || ! APP_ICON_IMAGE_NAME="$(plutil -extract groups.0.layers.0.image-name raw "$APP_ICON_COMPOSER_JSON" 2>/dev/null)" \
  || ! APP_ICON_LAYER_SCALE="$(plutil -extract groups.0.layers.0.position.scale raw "$APP_ICON_COMPOSER_JSON" 2>/dev/null)" \
  || ! APP_ICON_GROUP_SCALE="$(plutil -extract groups.0.position.scale raw "$APP_ICON_COMPOSER_JSON" 2>/dev/null)" \
  || ! APP_ICON_SHADOW_OPACITY="$(plutil -extract groups.0.shadow.opacity raw "$APP_ICON_COMPOSER_JSON" 2>/dev/null)"; then
  echo "error: $APP_ICON_COMPOSER_JSON must use the current Icon Composer schema" >&2
  exit 1
fi
if [[ "$APP_ICON_FILL" != *,0.00000 ]]; then
  echo "error: app icon canvas fill must remain fully transparent" >&2
  exit 1
fi
if [[ "$APP_ICON_IMAGE_NAME" != "AppIcon-Source.png" || "$APP_ICON_LAYER_SCALE" != "1" || "$APP_ICON_GROUP_SCALE" != "1.080000" || "$APP_ICON_SHADOW_OPACITY" != "0" ]]; then
  echo "error: app icon must keep its 100% layer, 108% static group, and zero static shadow" >&2
  exit 1
fi
if ! xcrun --find actool >/dev/null 2>&1; then
  echo "error: Xcode actool is required to compile the modern macOS app icon" >&2
  exit 1
fi

# Fingerprint the filename so LaunchServices cannot reuse a stale icon after the
# artwork changes while the development bundle identifier stays the same.
APP_ICON_DIGEST="$(shasum -a 256 "$APP_ICON_SOURCE" "$APP_ICON_COMPOSER_JSON" | awk '{print $1}' | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
APP_ICON_FILENAME="$APP_ICON_NAME-$APP_ICON_DIGEST.icns"

swift_build() {
  if [[ "$PACKAGE_PUBLIC" == true ]]; then
    swift build --disable-sandbox --configuration release "$@"
    return
  fi
  if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    swift build --disable-sandbox "$@"
  else
    swift build "$@"
  fi
}

cd "$ROOT_DIR"

python3 "$REPOSITORY_ROOT/script/validate_provider_trust_inputs.py" \
  --manifest-public-key "$PROVIDER_MANIFEST_PUBLIC_KEY" \
  --distribution-public-key "$PROVIDER_DISTRIBUTION_PUBLIC_KEY" \
  --index-url "$PROVIDER_DISTRIBUTION_INDEX_URL" \
  >/dev/null

release_run_lock() {
  if [[ "$RUN_LOCK_HELD" == true && -f "$RUN_LOCK_FILE" && "$(<"$RUN_LOCK_FILE")" == "$$" ]]; then
    rm -f "$RUN_LOCK_FILE"
  fi
  RUN_LOCK_HELD=false
}

cleanup_build_run() {
  local status="$?"

  if [[ -e "$STAGING_APP_BUNDLE" ]]; then
    rm -rf "$STAGING_APP_BUNDLE"
  fi

  if [[ -e "$PREVIOUS_APP_BUNDLE" ]]; then
    if [[ -e "$APP_BUNDLE" ]]; then
      rm -rf "$PREVIOUS_APP_BUNDLE"
    else
      mv "$PREVIOUS_APP_BUNDLE" "$APP_BUNDLE"
    fi
  fi

  if [[ -e "$PREPARED_NODE_RUNTIME_ROOT" ]]; then
    rm -rf "$PREPARED_NODE_RUNTIME_ROOT"
  fi
  if [[ -e "$PREPARED_QUICKJS_RUNTIME_ROOT" ]]; then
    rm -rf "$PREPARED_QUICKJS_RUNTIME_ROOT"
  fi
  if [[ -e "${PREPARED_NODE_NPM_ROOT%/npm}" ]]; then
    rm -rf "${PREPARED_NODE_NPM_ROOT%/npm}"
  fi

  release_run_lock
  trap - EXIT
  exit "$status"
}

acquire_run_lock() {
  local announced=false

  while ! /usr/bin/shlock -p "$$" -f "$RUN_LOCK_FILE"; do
    if [[ "$announced" == false ]]; then
      echo "Waiting for another NetVplayer build/run to finish..." >&2
      announced=true
    fi
    sleep 0.2
  done

  RUN_LOCK_HELD=true
  trap cleanup_build_run EXIT
}

app_process_path() {
  local pid="$1"
  lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
    | awk 'substr($0, 1, 1) == "n" { print substr($0, 2); exit }'
}

print_running_apps() {
  local pid
  local executable_path

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable_path="$(app_process_path "$pid")"
    echo "  pid=$pid path=${executable_path:-unknown}" >&2
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

stop_existing_apps() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "error: existing $APP_NAME processes did not exit" >&2
  print_running_apps
  return 1
}

remove_obsolete_app_bundles() {
  local obsolete_bundle

  for obsolete_bundle in "${OBSOLETE_APP_BUNDLES[@]}"; do
    if [[ "$obsolete_bundle" == "$APP_BUNDLE" || ! -e "$obsolete_bundle" ]]; then
      continue
    fi

    if [[ -x "$LSREGISTER_PATH" ]]; then
      "$LSREGISTER_PATH" -u "$obsolete_bundle" >/dev/null 2>&1 || true
    fi
    rm -rf "$obsolete_bundle"
    echo "Removed obsolete app bundle: $obsolete_bundle"
  done
}

expected_app_pid() {
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if [[ "$(app_process_path "$pid")" == "$INSTALLED_APP_BINARY" ]]; then
      echo "$pid"
      return 0
    fi
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)

  return 1
}

install_staged_app() {
  stop_existing_apps
  rm -rf "$PREVIOUS_APP_BUNDLE"

  if [[ -e "$APP_BUNDLE" ]]; then
    mv "$APP_BUNDLE" "$PREVIOUS_APP_BUNDLE"
  fi

  # Create the installed bundle at its visible path. Moving the hidden staging
  # directory preserves its filesystem identity, which can leave LaunchServices
  # treating the installed app as hidden after the first launch.
  if ! /usr/bin/ditto "$STAGING_APP_BUNDLE" "$APP_BUNDLE"; then
    rm -rf "$APP_BUNDLE"
    if [[ -e "$PREVIOUS_APP_BUNDLE" && ! -e "$APP_BUNDLE" ]]; then
      mv "$PREVIOUS_APP_BUNDLE" "$APP_BUNDLE"
    fi
    return 1
  fi
  rm -rf "$STAGING_APP_BUNDLE"

  if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"; then
    rm -rf "$APP_BUNDLE"
    if [[ -e "$PREVIOUS_APP_BUNDLE" ]]; then
      mv "$PREVIOUS_APP_BUNDLE" "$APP_BUNDLE"
    fi
    return 1
  fi

  rm -rf "$PREVIOUS_APP_BUNDLE"
}

wait_for_expected_app() {
  local pid

  for _ in {1..20}; do
    if pid="$(expected_app_pid)"; then
      echo "$pid"
      return 0
    fi
    sleep 0.25
  done

  echo "error: $APP_NAME did not stay running from $INSTALLED_APP_BINARY" >&2
  print_running_apps
  return 1
}

acquire_run_lock
if [[ "$PACKAGE_PUBLIC" != true ]]; then
  stop_existing_apps
fi
mkdir -p "$INSTALL_DIR"
if [[ "$PACKAGE_PUBLIC" != true ]]; then
  remove_obsolete_app_bundles
fi

NODE_RUNTIME_ARCHITECTURE="$(uname -m)"
case "$NODE_RUNTIME_ARCHITECTURE" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported Node runtime architecture: $NODE_RUNTIME_ARCHITECTURE" >&2
    exit 1
    ;;
esac
python3 "$REPOSITORY_ROOT/script/prepare_embedded_quickjs_runtime.py" \
  --lock "$QUICKJS_RUNTIME_LOCK" \
  --cache "$QUICKJS_RUNTIME_CACHE" \
  --output "$PREPARED_QUICKJS_RUNTIME_ROOT" \
  --architecture "$NODE_RUNTIME_ARCHITECTURE"
python3 "$REPOSITORY_ROOT/script/prepare_embedded_node_runtime.py" \
  --lock "$NODE_RUNTIME_LOCK" \
  --cache "$NODE_RUNTIME_CACHE" \
  --output "$PREPARED_NODE_RUNTIME_ROOT" \
  --npm-output "$PREPARED_NODE_NPM_ROOT" \
  --architecture "$NODE_RUNTIME_ARCHITECTURE"
python3 "$REPOSITORY_ROOT/script/validate_node_runtime.py" \
  --root "$PREPARED_NODE_RUNTIME_ROOT" \
  --executable "$PREPARED_NODE_EXECUTABLE" \
  --version 22
TORRENT_LOCK_DIGEST="$(shasum -a 256 "$TORRENT_BRIDGE_SOURCE/package-lock.json" | awk '{print $1}')"
NPM_VERSION="$("$PREPARED_NODE_EXECUTABLE" "$NPM_CLI_PATH" --version)"
TORRENT_RUNTIME_ID="$("$PREPARED_NODE_EXECUTABLE" -p '`${process.versions.node}-${process.versions.modules}-${process.platform}-${process.arch}`')-npm$NPM_VERSION"
TORRENT_INSTALL_DIGEST="$(printf '%s\n%s\n' "$TORRENT_LOCK_DIGEST" "$TORRENT_RUNTIME_ID" | shasum -a 256 | awk '{print $1}')"
TORRENT_INSTALL_STAMP="$TORRENT_BRIDGE_SOURCE/node_modules/.netvplayer-lock-sha"
if [[ "$PACKAGE_PUBLIC" == true || ! -f "$TORRENT_INSTALL_STAMP" || "$(<"$TORRENT_INSTALL_STAMP")" != "$TORRENT_INSTALL_DIGEST" ]]; then
  PATH="$PREPARED_NODE_RUNTIME_ROOT/bin:${PATH:-/usr/bin:/bin}" \
    npm_config_cache="${NETVPLAYER_NPM_CACHE:-/tmp/netvplayer-npm-cache}" \
    "$PREPARED_NODE_EXECUTABLE" "$NPM_CLI_PATH" ci \
    --prefix "$TORRENT_BRIDGE_SOURCE" \
    --omit=dev \
    --no-audit \
    --no-fund
  echo "$TORRENT_INSTALL_DIGEST" >"$TORRENT_INSTALL_STAMP"
fi
python3 "$REPOSITORY_ROOT/script/apply_torrent_bridge_replacements.py" \
  --root "$TORRENT_BRIDGE_SOURCE"
if ! (cd "$TORRENT_BRIDGE_SOURCE" && "$PREPARED_NODE_EXECUTABLE" --input-type=module -e "await import('webtorrent')"); then
  echo "error: WebTorrent bridge dependencies are not loadable for $TORRENT_RUNTIME_ID" >&2
  exit 1
fi
python3 "$REPOSITORY_ROOT/script/audit_torrent_bridge_licenses.py" \
  --root "$TORRENT_BRIDGE_SOURCE" \
  --check "$REPOSITORY_ROOT/docs/data/torrent-bridge-license-audit-2026-08-18.json"

swift_build --product "$APP_NAME"
BUILD_BIN_DIR="$(swift_build --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
BUILD_RESOURCE_BUNDLE="$BUILD_BIN_DIR/$APP_RESOURCE_BUNDLE_NAME"
BUILD_ARCHITECTURES="$(/usr/bin/lipo -archs "$BUILD_BINARY")"
if [[ "$BUILD_ARCHITECTURES" != "$NODE_RUNTIME_ARCHITECTURE" ]]; then
  echo "error: app architecture '$BUILD_ARCHITECTURES' does not match embedded Node '$NODE_RUNTIME_ARCHITECTURE'" >&2
  exit 1
fi

if [[ ! -s "$BUILD_RESOURCE_BUNDLE/ThemeBackgrounds/monochrome-flow.png" ]]; then
  echo "error: theme background resource is missing from $BUILD_RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$STAGING_APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_FILENAME</string>
  <key>CFBundleIconName</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>NetVplayerFeedbackRepositoryURL</key>
  <string>https://github.com/spudhero/NetVplayer</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

if [[ "$PACKAGE_PUBLIC" == true ]]; then
  plutil -insert NetVplayerSourcePolicy -string user-configured-only "$INFO_PLIST"
  plutil -replace NetVplayerFeedbackRepositoryURL -string https://github.com/spudhero/NetVplayer "$INFO_PLIST"
fi

if [[ -n "$PROVIDER_MANIFEST_PUBLIC_KEY" ]]; then
  plutil -insert NetVplayerProviderManifestEd25519PublicKey \
    -string "$PROVIDER_MANIFEST_PUBLIC_KEY" "$INFO_PLIST"
  plutil -insert NetVplayerProviderDistributionEd25519PublicKey \
    -string "$PROVIDER_DISTRIBUTION_PUBLIC_KEY" "$INFO_PLIST"
  plutil -insert NetVplayerProviderDistributionIndexURL \
    -string "$PROVIDER_DISTRIBUTION_INDEX_URL" "$INFO_PLIST"
fi

xcrun actool "$APP_ICON_COMPOSER_SOURCE" \
  --compile "$APP_RESOURCES" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --target-device mac \
  --app-icon "$APP_ICON_NAME" \
  --standalone-icon-behavior none \
  --output-partial-info-plist "$APP_ICON_PARTIAL_INFO" \
  --warnings \
  --errors \
  --notices \
  --output-format human-readable-text

if [[ ! -s "$APP_RESOURCES/Assets.car" ]]; then
  echo "error: actool did not produce $APP_RESOURCES/Assets.car" >&2
  exit 1
fi
rm -f "$APP_ICON_PARTIAL_INFO"
cp "$LEGACY_APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_FILENAME"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon-Runtime.png"
cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/$APP_RESOURCE_BUNDLE_NAME"
cp -R "$PREPARED_QUICKJS_RUNTIME_ROOT" "$BUNDLED_QUICKJS_RUNTIME_ROOT"
cp -R "$PREPARED_NODE_RUNTIME_ROOT" "$BUNDLED_NODE_RUNTIME_ROOT"
mkdir -p "$TORRENT_BRIDGE_DESTINATION"
cp "$TORRENT_BRIDGE_SOURCE/torrent-bridge.mjs" "$TORRENT_BRIDGE_DESTINATION/"
cp "$TORRENT_BRIDGE_SOURCE/package.json" "$TORRENT_BRIDGE_DESTINATION/"
cp "$TORRENT_BRIDGE_SOURCE/package-lock.json" "$TORRENT_BRIDGE_DESTINATION/"
cp -R "$TORRENT_BRIDGE_SOURCE/node_modules" "$TORRENT_BRIDGE_DESTINATION/"
cp -R "$TORRENT_BRIDGE_SOURCE/THIRD_PARTY_LICENSES" "$TORRENT_BRIDGE_DESTINATION/"

if [[ -n "${NETVPLAYER_LIBMPV_PATH:-}" && -z "${NETVPLAYER_LIBMPV_SOURCE:-}" ]]; then
  export NETVPLAYER_LIBMPV_SOURCE="$NETVPLAYER_LIBMPV_PATH"
fi
"$REPOSITORY_ROOT/script/vendor_libmpv.sh" "$STAGING_APP_BUNDLE" "$APP_BINARY"
find "$APP_FRAMEWORKS" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$BUNDLED_NODE_EXECUTABLE"
codesign --force --sign - "$BUNDLED_QUICKJS_EXECUTABLE"
if [[ -f "$BUNDLED_QUICKJS_POLYGLOT" ]]; then
  codesign --force --sign - "$BUNDLED_QUICKJS_POLYGLOT"
fi
if [[ -f "$BUNDLED_QUICKJS_BOOTSTRAP" ]]; then
  codesign --force --sign - "$BUNDLED_QUICKJS_BOOTSTRAP"
fi
codesign --force --sign - "$APP_BINARY"
codesign --force --deep --sign - "$STAGING_APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP_BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLED_NODE_EXECUTABLE"
codesign --verify --strict --verbose=2 "$BUNDLED_QUICKJS_EXECUTABLE"
if [[ -f "$BUNDLED_QUICKJS_POLYGLOT" ]]; then
  codesign --verify --strict --verbose=2 "$BUNDLED_QUICKJS_POLYGLOT"
fi
if [[ -f "$BUNDLED_QUICKJS_BOOTSTRAP" ]]; then
  codesign --verify --strict --verbose=2 "$BUNDLED_QUICKJS_BOOTSTRAP"
fi
python3 "$REPOSITORY_ROOT/script/validate_node_runtime.py" \
  --root "$BUNDLED_NODE_RUNTIME_ROOT" \
  --executable "$BUNDLED_NODE_EXECUTABLE" \
  --version 22
python3 "$REPOSITORY_ROOT/script/package_libmpv_runtime_licenses.py" \
  --app-bundle "$STAGING_APP_BUNDLE" \
  --audit-only
python3 "$REPOSITORY_ROOT/script/generate_release_sbom.py" \
  --app-bundle "$STAGING_APP_BUNDLE" \
  --package-resolved "$ROOT_DIR/Package.resolved" \
  --output-directory "$REPOSITORY_ROOT/dist/sbom"
if [[ "$PACKAGE_PUBLIC" == true ]]; then
  python3 "$REPOSITORY_ROOT/script/audit_source_free_app.py" \
    --repo "$REPOSITORY_ROOT" --app-bundle "$STAGING_APP_BUNDLE"
  /usr/bin/ditto "$STAGING_APP_BUNDLE" "$APP_BUNDLE"
  echo "Packaged source-free public shell at $APP_BUNDLE"
  exit 0
fi
install_staged_app
if [[ -x "$LSREGISTER_PATH" ]]; then
  "$LSREGISTER_PATH" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

open_app() {
  # A second launcher may have opened an old bundle during the build. Clear it
  # again immediately before launching the newly staged, signed bundle.
  stop_existing_apps
  : >"$LOG_FILE"
  /usr/bin/open -n "$APP_BUNDLE" --stdout "$LOG_FILE" --stderr "$LOG_FILE"
  LAUNCHED_APP_PID="$(wait_for_expected_app)"
}

case "$MODE" in
  run)
    open_app
    echo "Launched $APP_NAME (pid $LAUNCHED_APP_PID) from $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    release_run_lock
    mkdir -p "$(dirname "$APP_DIAGNOSTIC_LOG")"
    touch "$APP_DIAGNOSTIC_LOG"
    tail -F "$LOG_FILE" "$APP_DIAGNOSTIC_LOG"
    ;;
  --telemetry|telemetry)
    open_app
    release_run_lock
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\" OR process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    echo "Verified $APP_NAME (pid $LAUNCHED_APP_PID) is running from $APP_BUNDLE"
    ;;
  --capture-player-hud|capture-player-hud)
    OUTPUT_PATH="${2:-$REPOSITORY_ROOT/artifacts/visual-regression/player-hud-normal-1480x833.png}"
    CAPTURE_STATE="${3:-normal}"
    CAPTURE_VIEWPORT="${4:-1480x833}"
    FIXTURE_PATH="$REPOSITORY_ROOT/docs/design/player-ui/assets/w700d1q75cms.jpg"
    mkdir -p "$(dirname "$OUTPUT_PATH")"
    "$INSTALLED_APP_BINARY" \
      --visual-regression-player "$CAPTURE_STATE" \
      --visual-regression-fixture "$FIXTURE_PATH" \
      --visual-regression-viewport "$CAPTURE_VIEWPORT" \
      --visual-regression-output "$OUTPUT_PATH"
    if [[ ! -s "$OUTPUT_PATH" ]]; then
      echo "error: player visual regression capture was not written: $OUTPUT_PATH" >&2
      exit 1
    fi
    echo "Captured player HUD ($CAPTURE_STATE, $CAPTURE_VIEWPORT): $OUTPUT_PATH"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--capture-player-hud [output.png] [state] [viewport]]" >&2
    exit 2
    ;;
esac
