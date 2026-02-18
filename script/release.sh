#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Release script for ApplePhotosPublisher
# Builds a signed, notarized release ZIP for distribution
# =============================================================================

# Configuration - set these environment variables or edit here
DEVELOPER_ID="${DEVELOPER_ID:-}"  # e.g., "Developer ID Application: Your Name (TEAMID)"
APPLE_ID="${APPLE_ID:-}"          # e.g., "you@example.com"
TEAM_ID="${TEAM_ID:-}"            # e.g., "ABCD1234"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"  # stored credentials profile

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMPORTER_DIR="$PROJECT_ROOT/importer"
PLUGIN_NAME="ApplePhotosPublisher.lrplugin"
PLUGIN_DIR="$PROJECT_ROOT/$PLUGIN_NAME"
BUILD_DIR="$PROJECT_ROOT/tmp/build"
BINARY_NAME="lrphotosimporter"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
SKIP_NOTARIZE=false
SKIP_SIGN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        --skip-sign)
            SKIP_SIGN=true
            SKIP_NOTARIZE=true  # Can't notarize without signing
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-sign       Skip code signing (for local testing)"
            echo "  --skip-notarize   Skip notarization (still signs)"
            echo "  -h, --help        Show this help"
            echo ""
            echo "Environment variables:"
            echo "  DEVELOPER_ID      Developer ID certificate name"
            echo "  APPLE_ID          Apple ID email for notarization"
            echo "  TEAM_ID           Apple Developer Team ID"
            echo "  KEYCHAIN_PROFILE  notarytool stored credentials profile"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
if [[ "$SKIP_SIGN" == false && -z "$DEVELOPER_ID" ]]; then
    log_error "DEVELOPER_ID not set. Set it or use --skip-sign for testing."
    log_error "Example: export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'"
    exit 1
fi

if [[ "$SKIP_NOTARIZE" == false ]]; then
    if [[ -z "$TEAM_ID" ]]; then
        log_error "TEAM_ID not set. Required for notarization."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Get version from git
# -----------------------------------------------------------------------------
cd "$PROJECT_ROOT"
if git describe --tags --exact-match HEAD 2>/dev/null; then
    VERSION=$(git describe --tags --exact-match HEAD)
else
    VERSION="dev-$(git rev-parse --short HEAD)"
fi
log_info "Building version: $VERSION"

# -----------------------------------------------------------------------------
# Clean and prepare build directory
# -----------------------------------------------------------------------------
log_info "Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# -----------------------------------------------------------------------------
# Build universal Swift binary
# -----------------------------------------------------------------------------
log_info "Building universal Swift binary (arm64 + x86_64)..."
cd "$IMPORTER_DIR"

swift build -c release --arch arm64 --arch x86_64

BINARY_PATH="$IMPORTER_DIR/.build/apple/Products/Release/$BINARY_NAME"

if [[ ! -f "$BINARY_PATH" ]]; then
    log_error "Binary not found at $BINARY_PATH"
    exit 1
fi

log_info "Binary built: $(file "$BINARY_PATH")"

# -----------------------------------------------------------------------------
# Sign the binary
# -----------------------------------------------------------------------------
if [[ "$SKIP_SIGN" == false ]]; then
    log_info "Signing binary with Developer ID..."
    codesign --force \
             --sign "$DEVELOPER_ID" \
             --options runtime \
             --timestamp \
             "$BINARY_PATH"

    log_info "Verifying signature..."
    codesign --verify --verbose "$BINARY_PATH"
else
    log_warn "Skipping code signing"
fi

# -----------------------------------------------------------------------------
# Notarize the binary
# -----------------------------------------------------------------------------
if [[ "$SKIP_NOTARIZE" == false ]]; then
    log_info "Preparing binary for notarization..."

    NOTARIZE_ZIP="$BUILD_DIR/$BINARY_NAME-notarize.zip"
    ditto -c -k --keepParent "$BINARY_PATH" "$NOTARIZE_ZIP"

    log_info "Submitting for notarization (this may take a few minutes)..."

    xcrun notarytool submit "$NOTARIZE_ZIP" \
          --keychain-profile "$KEYCHAIN_PROFILE" \
          --wait

    rm "$NOTARIZE_ZIP"
    log_info "Notarization complete"
else
    log_warn "Skipping notarization"
fi

# -----------------------------------------------------------------------------
# Copy plugin and bundle binary
# -----------------------------------------------------------------------------
log_info "Assembling plugin package..."

RELEASE_PLUGIN="$BUILD_DIR/$PLUGIN_NAME"
cp -R "$PLUGIN_DIR" "$RELEASE_PLUGIN"

# Remove any existing bin directory
mkdir -p "$RELEASE_PLUGIN/bin"
cp "$BINARY_PATH" "$RELEASE_PLUGIN/bin/"

# Set executable permission
chmod +x "$RELEASE_PLUGIN/bin/$BINARY_NAME"

# -----------------------------------------------------------------------------
# Create release ZIP
# -----------------------------------------------------------------------------
ZIP_NAME="ApplePhotosPublisher-${VERSION}.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

log_info "Creating release ZIP: $ZIP_NAME"
cd "$BUILD_DIR"
ditto -c -k --keepParent "$PLUGIN_NAME" "$ZIP_PATH"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "=========================================="
log_info "Release build complete!"
log_info "=========================================="
echo ""
echo "  Version:  $VERSION"
echo "  Output:   $ZIP_PATH"
echo "  Size:     $(du -h "$ZIP_PATH" | cut -f1)"
echo ""

if [[ "$SKIP_SIGN" == true ]]; then
    log_warn "Binary is NOT signed - for testing only!"
elif [[ "$SKIP_NOTARIZE" == true ]]; then
    log_warn "Binary is signed but NOT notarized"
    log_warn "Users may see Gatekeeper warnings"
else
    log_info "Binary is signed and notarized - ready for distribution"
fi

echo ""
echo "To upload to GitHub Releases:"
echo "  gh release create $VERSION '$ZIP_PATH' --title '$VERSION' --notes 'Release notes here'"
echo ""
