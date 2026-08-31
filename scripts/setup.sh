#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking for zig..."
ZIG_REQUIRED="$($SCRIPT_DIR/required-zig-version.sh)"
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed (required: $ZIG_REQUIRED)." >&2
    echo "Download: https://ziglang.org/download/${ZIG_REQUIRED}/" >&2
    exit 1
fi
ZIG_FOUND="$(zig version)"
if [[ "$ZIG_FOUND" != "$ZIG_REQUIRED" ]]; then
    echo "Error: exact Zig version required: $ZIG_REQUIRED; found: $ZIG_FOUND" >&2
    echo "Download: https://ziglang.org/download/${ZIG_REQUIRED}/" >&2
    exit 1
fi

"$SCRIPT_DIR/ensure-ghosttykit.sh"

echo "==> Setup complete!"
echo ""
echo "You can now build and run the app:"
echo "  ./scripts/reload.sh --tag first-run"
