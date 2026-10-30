#!/usr/bin/env bash
set -euo pipefail

# Assemble an app so Launch Services can give the importer its own TCC identity.
# Apply a complete local signature; release callers replace it with Developer ID.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BINARY_PATH="${1:?Usage: package-helper.sh BINARY_PATH APP_PATH}"
APP_PATH="${2:?Usage: package-helper.sh BINARY_PATH APP_PATH}"

mkdir -p "$APP_PATH/Contents/MacOS"
cp "$PROJECT_ROOT/importer/Sources/lrphotosimporter/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/lrphotosimporter"
cp "$(dirname "$BINARY_PATH")/lrphotoslauncher" "$APP_PATH/Contents/MacOS/lrphotoslauncher"
chmod +x "$APP_PATH/Contents/MacOS/lrphotosimporter"
chmod +x "$APP_PATH/Contents/MacOS/lrphotoslauncher"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

# The linker's ad-hoc signature only covers the executable, not this app's
# Info.plist or bundle identity. TCC's initial prompt may succeed while the
# Photos daemon rejects that incomplete identity on a subsequent check.
/usr/bin/codesign --force --sign - --timestamp=none --options runtime "$APP_PATH/Contents/MacOS/lrphotoslauncher"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$PROJECT_ROOT/importer/Entitlements.plist" "$APP_PATH"
/usr/bin/codesign --verify --strict --all-architectures --verbose "$APP_PATH"
