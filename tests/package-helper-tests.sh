#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_ROOT/tmp/build/ApplePhotosPublisher.lrplugin/bin/Apple Photos Publisher for Lightroom Classic.app"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/Signing test.app"

bash "$PROJECT_ROOT/script/package-helper.sh" "$SOURCE_APP/Contents/MacOS/lrphotosimporter" "$TEST_APP"
/usr/bin/codesign --verify --strict --all-architectures "$TEST_APP"
SIGNATURE=$(/usr/bin/codesign -d --verbose=4 "$TEST_APP" 2>&1)
[[ "$SIGNATURE" == *'Identifier=org.buddin.lrphotossync.lrphotosimporter'* ]]
[[ "$SIGNATURE" != *'Info.plist=not bound'* ]]
/usr/bin/codesign -d --entitlements - --xml "$TEST_APP" > "$TEST_DIR/entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.photos-library' "$TEST_DIR/entitlements.plist")" == 'true' ]]

# Regression: the linker-only signature did not cover the app's Info.plist.
/usr/bin/plutil -replace NSPhotoLibraryUsageDescription -string 'tampered' "$TEST_APP/Contents/Info.plist"
if /usr/bin/codesign --verify --strict "$TEST_APP" 2>/dev/null; then
    echo 'FAIL: modifying Info.plist did not invalidate the signature' >&2
    exit 1
fi
echo 'PASS: helper identity, universal signature, and Info.plist tamper detection'
