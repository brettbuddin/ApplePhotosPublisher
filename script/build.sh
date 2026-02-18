#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Build script for ApplePhotosPublisher
# Builds the Swift binary for development or release (without packaging)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IMPORTER_DIR="$PROJECT_ROOT/importer"
PLUGIN_NAME="ApplePhotosPublisher.lrplugin"
PLUGIN_DIR="$PROJECT_ROOT/$PLUGIN_NAME"
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
BUILD_CONFIG="debug"
INSTALL_TO_PLUGIN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            BUILD_CONFIG="release"
            shift
            ;;
        --install)
            INSTALL_TO_PLUGIN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --release    Build release configuration (default: debug)"
            echo "  --install    Copy binary to plugin after building"
            echo "  -h, --help   Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                    # Debug build"
            echo "  $0 --release          # Release build"
            echo "  $0 --install          # Debug build, install to plugin"
            echo "  $0 --release --install # Release build, install to plugin"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Build Swift binary
# -----------------------------------------------------------------------------
cd "$IMPORTER_DIR"

if [[ "$BUILD_CONFIG" == "release" ]]; then
    log_info "Building release universal binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64
    BINARY_PATH="$IMPORTER_DIR/.build/apple/Products/Release/$BINARY_NAME"
else
    log_info "Building debug binary..."
    swift build
    BINARY_PATH="$IMPORTER_DIR/.build/debug/$BINARY_NAME"
fi

if [[ ! -f "$BINARY_PATH" ]]; then
    log_error "Binary not found at $BINARY_PATH"
    exit 1
fi

log_info "Binary built: $BINARY_PATH"
if [[ "$BUILD_CONFIG" == "release" ]]; then
    log_info "Architectures: $(file "$BINARY_PATH" | grep -o 'arm64\|x86_64' | tr '\n' ' ')"
fi

# -----------------------------------------------------------------------------
# Install to plugin (optional)
# -----------------------------------------------------------------------------
if [[ "$INSTALL_TO_PLUGIN" == true ]]; then
    log_info "Installing binary to plugin..."
    mkdir -p "$PLUGIN_DIR/bin"
    cp "$BINARY_PATH" "$PLUGIN_DIR/bin/"
    chmod +x "$PLUGIN_DIR/bin/$BINARY_NAME"
    log_info "Installed to: $PLUGIN_DIR/bin/$BINARY_NAME"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
log_info "Build complete ($BUILD_CONFIG)"
echo "  Binary: $BINARY_PATH"
