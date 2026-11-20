#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-bundle> <executable-path>" >&2
  exit 64
fi

APP_BUNDLE="$1"
EXECUTABLE_PATH="$2"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SCRIPT_PATH="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
LICENSE_FALLBACK_ROOT="$SCRIPT_DIR/../NetVplayer/Resources/ThirdPartyLicenses"
mkdir -p "$FRAMEWORKS_DIR"

copy_prepared_runtime() {
  local runtime_bundle="$1"
  local runtime_frameworks="$runtime_bundle/Contents/Frameworks"
  local runtime_licenses="$runtime_bundle/Contents/Resources/ThirdPartyLicenses"
  local runtime_license_texts="$runtime_licenses/libmpv"
  # Query the selected binary in a fresh process. Both the default bundle and
  # explicit runtime override must retain the shared DASH/HLS/MP4 contract.
  python3 "$SCRIPT_DIR/verify_playback_runtime.py" --bundle "$runtime_bundle"
  if [[ ! -f "$runtime_frameworks/libmpv.2.dylib" ]]; then
    echo "prepared libmpv runtime is missing libmpv.2.dylib: $runtime_frameworks" >&2
    exit 66
  fi
  if [[ ! -f "$runtime_licenses/libmpv-runtime.json" || ! -f "$runtime_licenses/libmpv-runtime.md" ]]; then
    echo "prepared libmpv runtime is missing license metadata: $runtime_licenses" >&2
    exit 66
  fi
  if [[ ! -d "$runtime_license_texts" || -z "$(find "$runtime_license_texts" -type f -print -quit)" ]]; then
    echo "prepared libmpv runtime is missing license texts: $runtime_license_texts" >&2
    exit 66
  fi
  # Runtime overrides can originate from a full App. The player owns only
  # these dylibs; preserve Sparkle and other frameworks assembled separately.
  for runtime_dylib in "$runtime_frameworks"/*.dylib; do
    [[ -f "$runtime_dylib" ]] || continue
    cp -f "$runtime_dylib" "$FRAMEWORKS_DIR/"
  done
  mkdir -p "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses"
  cp "$runtime_licenses/libmpv-runtime.json" "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/"
  cp "$runtime_licenses/libmpv-runtime.md" "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/"
  cp -R "$runtime_license_texts" "$APP_BUNDLE/Contents/Resources/ThirdPartyLicenses/"
  if [[ -f "$runtime_bundle/Contents/Resources/dolby-runtime-build.json" ]]; then
    cp "$runtime_bundle/Contents/Resources/dolby-runtime-build.json" "$APP_BUNDLE/Contents/Resources/"
  fi
  if [[ -f "$runtime_bundle/Contents/Resources/dash-runtime-build.json" ]]; then
    cp "$runtime_bundle/Contents/Resources/dash-runtime-build.json" "$APP_BUNDLE/Contents/Resources/"
  fi
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH" 2>/dev/null || true
  echo "Bundled prepared libmpv runtime: $(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' | wc -l | tr -d ' ') dylibs"
}

if [[ -n "${NETVPLAYER_LIBMPV_RUNTIME_BUNDLE:-}" ]]; then
  copy_prepared_runtime "$NETVPLAYER_LIBMPV_RUNTIME_BUNDLE"
  exit 0
fi

# Normal rebuilds must retain the implemented Dolby backend. An explicit stock
# override remains available for compatibility tests, never as a silent fallback.
DEFAULT_DOLBY_RUNTIME="$SCRIPT_DIR/../NetVplayer/.build/dolby-runtime/runtime.app"
if [[ "${NETVPLAYER_ALLOW_STOCK_LIBMPV:-0}" != "1" ]]; then
  python3 - "$DEFAULT_DOLBY_RUNTIME" "$SCRIPT_DIR/runtime/mpv" <<'PY'
import hashlib, json, sys
from pathlib import Path
bundle, overlay = map(Path, sys.argv[1:])
receipt = bundle / 'Contents/Resources/dolby-runtime-build.json'
if not receipt.is_file():
    sys.exit('Dolby runtime missing. Build with script/build_dolby_runtime.py --work-dir NetVplayer/.build/dolby-runtime, or set NETVPLAYER_LIBMPV_RUNTIME_BUNDLE. See script/runtime/README.md.')
saved = json.loads(receipt.read_text())
sys.path.insert(0, str(overlay.parent.parent))
import build_truehd_objects
if saved.get('truehdObjects', {}).get('commit') != build_truehd_objects.COMMIT or saved.get('truehdObjects', {}).get('features') != ['matrix-interpolation']:
    sys.exit('Exact TrueHD object decoder missing or outdated. Rebuild the prepared runtime.')
if saved.get('truehdBuilderSHA256') != hashlib.sha256((overlay.parent.parent / 'build_truehd_objects.py').read_bytes()).hexdigest():
    sys.exit('TrueHD object build recipe changed. Rebuild the prepared runtime.')
current = {p.relative_to(overlay).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in sorted(overlay.rglob('*')) if p.is_file()}
if current != saved.get('overlay'):
    sys.exit('Dolby runtime sources changed. Rebuild the prepared runtime before packaging.')
for name, expected in saved.get('binaries', {}).items():
    file = bundle / 'Contents/Frameworks' / name
    if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
        sys.exit('Dolby runtime binary hash mismatch: ' + name)
PY
  copy_prepared_runtime "$DEFAULT_DOLBY_RUNTIME"
  exit 0
fi

find_libmpv() {
  if [[ -n "${NETVPLAYER_LIBMPV_SOURCE:-}" && -f "$NETVPLAYER_LIBMPV_SOURCE" ]]; then
    echo "$NETVPLAYER_LIBMPV_SOURCE"
    return
  fi

  for candidate in \
    "/opt/homebrew/opt/mpv/lib/libmpv.2.dylib" \
    "/usr/local/opt/mpv/lib/libmpv.2.dylib"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "libmpv.2.dylib not found. Install mpv with Homebrew or set NETVPLAYER_LIBMPV_SOURCE." >&2
  exit 66
}

is_vendor_dependency() {
  local path="$1"
  case "$path" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
}

COPIED_KEYS=""
declare -a COPIED_FILES=()
declare -a COPIED_SOURCE_RECORDS=()

has_copied() {
  local key="$1"
  [[ "$COPIED_KEYS" == *"
$key
"* ]]
}

mark_copied() {
  local key="$1"
  COPIED_KEYS="${COPIED_KEYS}
$key
"
}

copy_dylib_recursive() {
  local source="$1"
  if [[ ! -f "$source" ]]; then
    return
  fi

  local resolved
  resolved="$(realpath "$source")"
  if has_copied "$resolved"; then
    return
  fi
  mark_copied "$resolved"

  local base dest
  base="$(basename "$source")"
  dest="$FRAMEWORKS_DIR/$base"
  cp -f "$resolved" "$dest"
  chmod u+w "$dest"
  COPIED_FILES+=("$dest")
  COPIED_SOURCE_RECORDS+=("$base"$'\t'"$resolved")

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == @* ]] && continue
    is_vendor_dependency "$dep" || continue
    copy_dylib_recursive "$dep"
  done < <(otool -L "$resolved" | awk 'NR > 1 { print $1 }')
}

patch_dylib() {
  local dylib="$1"
  local base
  base="$(basename "$dylib")"
  install_name_tool -id "@rpath/$base" "$dylib" 2>/dev/null || true

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == @* ]] && continue
    is_vendor_dependency "$dep" || continue

    local dep_base="$FRAMEWORKS_DIR/$(basename "$dep")"
    if [[ -f "$dep_base" ]]; then
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dylib" 2>/dev/null || true
    fi
  done < <(otool -L "$dylib" | awk 'NR > 1 { print $1 }')
}

LIBMPV_SOURCE="$(find_libmpv)"
copy_dylib_recursive "$LIBMPV_SOURCE"

for dylib in "${COPIED_FILES[@]}"; do
  patch_dylib "$dylib"
done

SOURCE_MAPPING="$(mktemp "${TMPDIR:-/tmp}/netvplayer-libmpv-sources.XXXXXX")"
trap 'rm -f "$SOURCE_MAPPING"' EXIT
printf '%s\n' "${COPIED_SOURCE_RECORDS[@]}" >"$SOURCE_MAPPING"
python3 "$SCRIPT_DIR/package_libmpv_runtime_licenses.py" \
  --app-bundle "$APP_BUNDLE" \
  --mapping "$SOURCE_MAPPING" \
  --fallback-root "$LICENSE_FALLBACK_ROOT"
rm -f "$SOURCE_MAPPING"
trap - EXIT

install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH" 2>/dev/null || true

echo "Bundled libmpv runtime: ${#COPIED_FILES[@]} dylibs"
