#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_DIR="$(mktemp -d /tmp/foldertone-engine.XXXXXXXX)"
cleanup() {
  if [[ "$TASK_DIR" == /tmp/foldertone-engine.* ]]; then
    rm -rf "$TASK_DIR"
  fi
}
trap cleanup EXIT

xcrun swiftc -D DEBUG -D SYNC_STANDALONE -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  "$PROJECT_ROOT/Foldertone/MusicLibrary.swift" \
  "$PROJECT_ROOT/Foldertone/SourceObserver.swift" \
  "$PROJECT_ROOT/Foldertone/PlaybackQueue.swift" \
  "$PROJECT_ROOT/Foldertone/SampleLibrary.swift" \
  "$PROJECT_ROOT/FoldertoneTests/FoldertoneTests.swift" \
  "$PROJECT_ROOT/scripts/CheckEngine.swift" \
  -o "$TASK_DIR/check-engine"

CFFIXED_USER_HOME="$TASK_DIR/home" "$TASK_DIR/check-engine" "$TASK_DIR" "${1:-all}"
