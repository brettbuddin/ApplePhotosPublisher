#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LUA_DIR="$PROJECT_DIR/ApplePhotosPublisher.lrplugin"

exit_code=0

echo "=== Linting Shell Scripts ==="
if command -v shellcheck &> /dev/null; then
    find "$SCRIPT_DIR" -name "*.sh" -type f -exec shellcheck {} + || exit_code=1
else
    echo "Warning: shellcheck not installed, skipping shell linting"
    echo "Install with: brew install shellcheck"
fi

echo "=== Linting Lua Code ==="
if command -v lua-language-server &> /dev/null; then
    lua-language-server --check "$LUA_DIR" --configpath "$PROJECT_DIR/.luarc.json" --logpath /tmp/lua-ls-lint 2>&1 | grep -v "^Diagnosis complete" || true

    # Check if diagnosis report exists and has errors
    REPORT_FILE="/tmp/lua-ls-lint/check.json"
    if [[ -f "$REPORT_FILE" ]]; then
        error_count=$(jq 'to_entries | map(.value | length) | add // 0' "$REPORT_FILE" 2>/dev/null || echo "0")
        if [[ "$error_count" -gt 0 ]]; then
            echo "Found $error_count diagnostic issues:"
            jq -r 'to_entries[] | .key as $file | .value[] | "\($file):\(.range.start.line + 1): [\(.code)] \(.message)"' "$REPORT_FILE" 2>/dev/null
            exit_code=1
        else
            echo "No Lua issues found."
        fi
        rm -f "$REPORT_FILE"
    fi
else
    echo "Warning: lua-language-server not installed, skipping Lua linting"
    echo "Install with: brew install lua-language-server"
fi

exit $exit_code
