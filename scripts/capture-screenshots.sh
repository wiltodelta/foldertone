#!/bin/bash
# Capture the README screenshots in light and dark appearance.
# Usage: scripts/capture-screenshots.sh MUSIC_FOLDER
# MUSIC_FOLDER must hold synthetic audio only; its name becomes the playlist name.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:?usage: scripts/capture-screenshots.sh MUSIC_FOLDER}"
[[ -d "$SOURCE" ]] || { echo "Not a folder: $SOURCE" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foldertone-screenshots.XXXXXXXX")"
DEVICE=""
cleanup() {
  if [[ -n "$DEVICE" ]]; then
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The simulator reads the copy from the host, outside privacy-protected folders.
cp -R "$SOURCE" "$WORK/"
FOLDER="$WORK/$(basename "$SOURCE")"

# Without a runtime argument simctl picks the newest one for the device type.
DEVICE="$(xcrun simctl create "foldertone-screenshots-$$" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)"
echo "Booting $DEVICE; a first boot can take several minutes."
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl status_bar "$DEVICE" override --time 9:41 --dataNetwork wifi --wifiMode active \
  --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

DESTINATION="platform=iOS Simulator,id=$DEVICE"
xcodebuild build-for-testing -project "$ROOT/Foldertone.xcodeproj" -scheme Foldertone \
  -destination "$DESTINATION" -derivedDataPath "$WORK/build" CODE_SIGNING_ALLOWED=NO -quiet

# XCUIDevice.appearance does not restyle the running app here, so each
# appearance gets its own run.
mkdir -p "$ROOT/screenshots"
for appearance in light dark; do
  xcrun simctl ui "$DEVICE" appearance "$appearance"
  RESULT="$WORK/$appearance.xcresult"
  TEST_RUNNER_FOLDERTONE_SCREENSHOT_FOLDER="$FOLDER" xcodebuild test-without-building \
    -project "$ROOT/Foldertone.xcodeproj" -scheme Foldertone -destination "$DESTINATION" \
    -derivedDataPath "$WORK/build" -resultBundlePath "$RESULT" \
    -only-testing:FoldertoneUITests/FoldertoneUITests/testReadmeScreenshots -quiet
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/$appearance" >/dev/null
  suffix=""
  [[ "$appearance" == dark ]] && suffix="-dark"
  python3 - "$WORK/$appearance" "$ROOT/screenshots" "$suffix" <<'EOF'
import json, os, shutil, sys
source, target, suffix = sys.argv[1:]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"].split("_")[0]
        shutil.copy(os.path.join(source, attachment["exportedFileName"]),
                    os.path.join(target, f"{name}{suffix}.png"))
EOF
done

# Full simulator resolution: the personal website imports these files.
ls -l "$ROOT/screenshots"
