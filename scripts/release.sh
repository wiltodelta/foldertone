#!/bin/bash
# Archive, upload and prepare the tagged App Store release with the App Store Connect API key.
# Usage: scripts/release.sh [--dry-run] [--submit]
#   --dry-run  build and check the archive, skip the upload, and only read App Store Connect
#   --submit   send the review submission after the build is attached
# Reads ASC_KEY_ID, ASC_ISSUER_ID and optional ASC_KEY_PATH from the environment or .env.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DRY_RUN=""
SUBMIT=""
for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN="--dry-run" ;;
    --submit) SUBMIT="--submit" ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

if [[ -f .env ]]; then set -a; source .env; set +a; fi
: "${ASC_KEY_ID:?Set ASC_KEY_ID; see .env.example}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID; see .env.example}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[[ -f "$KEY_PATH" ]] || { echo "Missing API key file $KEY_PATH" >&2; exit 1; }

setting() {
  grep -o "$1 = [^;]*" Foldertone.xcodeproj/project.pbxproj | sort -u | awk '{print $3}'
}
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
TEAM="$(setting DEVELOPMENT_TEAM)"
[[ "$VERSION$BUILD$TEAM" != *$'\n'* ]] || { echo "Targets disagree on version, build or team" >&2; exit 1; }
TAG="v$VERSION"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash changes first" >&2; exit 1; }
HEAD="$(git rev-parse HEAD)"
[[ "$(git rev-parse "$TAG^{commit}" 2>/dev/null)" == "$HEAD" ]] ||
  { echo "Tag $TAG must point at HEAD; tag only after CI passes" >&2; exit 1; }
[[ "$(git cat-file -t "$TAG")" == tag ]] || { echo "$TAG must be annotated; its body is What's New" >&2; exit 1; }
CI="$(gh run list --commit "$HEAD" --workflow build.yml --json conclusion -q '.[0].conclusion')"
[[ "$CI" == success ]] || { echo "CI on $HEAD is '${CI:-missing}', not success" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foldertone-release.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git tag -l --format='%(contents:body)' "$TAG" | sed '/-----BEGIN SSH SIGNATURE-----/,$d' > "$WORK/whats-new.txt"
[[ -s "$WORK/whats-new.txt" ]] || { echo "$TAG has no body for What's New" >&2; exit 1; }

asc() {
  ASC_KEY_PATH="$KEY_PATH" uv run --script scripts/asc.py "$@" release \
    --version "$VERSION" --build "$BUILD" --whats-new-file "$WORK/whats-new.txt" $SUBMIT
}
# Read-only preflight: a released version, a bad key or a missing localization fails here,
# before minutes of archiving and uploading.
echo "Checking App Store Connect before building"
asc --dry-run

AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
echo "Archiving Foldertone $VERSION ($BUILD) from $HEAD"
xcodebuild archive -project Foldertone.xcodeproj -scheme Foldertone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/Foldertone.xcarchive" "${AUTH[@]}" -quiet

APP="$WORK/Foldertone.xcarchive/Products/Applications/Foldertone.app"
[[ -f "$APP/PrivacyInfo.xcprivacy" ]] || { echo "Archive lacks PrivacyInfo.xcprivacy" >&2; exit 1; }
[[ -d "$WORK/Foldertone.xcarchive/dSYMs/Foldertone.app.dSYM" ]] || { echo "Archive lacks a dSYM" >&2; exit 1; }
DEBUG_FLAGS='--(sample-library|sample-file|empty-library|library-folder|isolated-storage)'
if strings "$APP/Foldertone" | grep -Eq -- "$DEBUG_FLAGS"; then
  echo "Release binary contains a Debug launch argument" >&2; exit 1
fi

if [[ -z "$DRY_RUN" ]]; then
  cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
  echo "Uploading $VERSION ($BUILD)"
  xcodebuild -exportArchive -archivePath "$WORK/Foldertone.xcarchive" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" "${AUTH[@]}"
  asc
else
  echo "Dry run: archive checked, upload and App Store Connect writes skipped"
fi
