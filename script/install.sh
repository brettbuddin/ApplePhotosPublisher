#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Install script for ApplePhotosPublisher
# Builds the importer binary and installs the plugin to Lightroom Classic
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_NAME="ApplePhotosPublisher.lrplugin"
PLUGIN_DIR="$PROJECT_ROOT/$PLUGIN_NAME"
MODULES_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Build release binary and install to plugin
log_info "Building release binary..."
"$SCRIPT_DIR/build.sh" --release --install

# Copy plugin to Lightroom Modules
log_info "Installing plugin to Lightroom Classic..."
mkdir -p "$MODULES_DIR"
rm -rf "$MODULES_DIR/$PLUGIN_NAME"
cp -R "$PLUGIN_DIR" "$MODULES_DIR/$PLUGIN_NAME"
log_info "Installed to: $MODULES_DIR/$PLUGIN_NAME"

log_info "Installation complete. Restart Lightroom Classic if it is running."
