#!/bin/bash
# Run XCTest on a fresh Simulator without opening Simulator.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${IOS_UI_RUNNER:-$HOME/Documents/GitHub/claude-config/bin/ios-ui-test.py}"
exec uv run --python 3.14 "$RUNNER" --project "$ROOT/Foldertone.xcodeproj" --scheme Foldertone "$@"
