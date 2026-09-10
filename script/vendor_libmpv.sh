#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-bundle> <executable-path>" >&2
  exit 64
fi

APP_BUNDLE="$1"
EXECUTABLE_PATH="$2"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LICENSE_FALLBACK_ROOT="$SCRIPT_DIR/../NetVplayer/Resources/ThirdPartyLicenses"
mkdir -p "$FRAMEWORKS_DIR"

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
