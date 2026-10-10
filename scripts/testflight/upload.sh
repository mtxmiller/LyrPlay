#!/bin/bash
# Archive, upload to App Store Connect, and hand the build to TestFlight groups.
#
#   scripts/testflight/upload.sh ios|tvos [--notes-file FILE] [--groups "A,B"] [--no-distribute]
#
# Builds exactly what's committed (refuses uncommitted tracked changes), with
# the version and build number already in project.pbxproj — /cut-build sets
# those. Config: ~/.config/lyrplay/testflight.env (see asc.py).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$REPO/scripts/testflight"
CONFIG="$HOME/.config/lyrplay/testflight.env"

PLATFORM="${1:-}"
shift || true
NOTES_FILE=""
GROUPS_ARG=()
DISTRIBUTE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --groups) GROUPS_ARG=(--groups "$2"); shift 2 ;;
    --no-distribute) DISTRIBUTE=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$PLATFORM" in
  ios)  SCHEME="LMS_StreamTest";      DEST="generic/platform=iOS" ;;
  tvos) SCHEME="LMS_StreamTest-tvOS"; DEST="generic/platform=tvOS" ;;
  *) echo "Usage: $0 ios|tvos [--notes-file FILE] [--groups \"A,B\"] [--no-distribute]" >&2; exit 2 ;;
esac

[ -f "$CONFIG" ] || { echo "Missing $CONFIG (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, TESTFLIGHT_GROUPS)" >&2; exit 1; }
# KEY=VALUE lines, read as data (values can contain spaces, e.g. group names).
while IFS='=' read -r key value; do
  case "$key" in
    ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH) value="${value%\"}"; printf -v "$key" '%s' "${value#\"}" ;;
  esac
done < <(grep -E '^[A-Z_]+=' "$CONFIG")
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
  [ -n "${!v:-}" ] || { echo "$v missing from $CONFIG" >&2; exit 1; }
done
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cd "$REPO"
if ! git diff --quiet HEAD --; then
  echo "Uncommitted changes to tracked files — commit first so the build matches a commit." >&2
  exit 1
fi

SETTINGS="$(xcodebuild -workspace LMS_StreamTest.xcworkspace -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)"
# Only the app target's block (a scheme can list Pods targets too).
setting() {
  echo "$SETTINGS" | awk -v t="target $SCHEME:" -v k="$1" '
    /^Build settings for/ { inapp = (index($0, t) > 0) }
    inapp && $1 == k { print $3; exit }'
}
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "Couldn't read version/build from build settings" >&2; exit 1; }
echo "==> $PLATFORM $VERSION ($BUILD) from $(git rev-parse --short HEAD) on $(git branch --show-current)"

OUT="$REPO/build/testflight/$PLATFORM-$VERSION-$BUILD"
rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/LyrPlay.xcarchive"

echo "==> Archiving (log: $OUT/archive.log)"
if ! xcodebuild archive -workspace LMS_StreamTest.xcworkspace -scheme "$SCHEME" \
     -configuration Release -destination "$DEST" -archivePath "$ARCHIVE" \
     "${AUTH[@]}" > "$OUT/archive.log" 2>&1; then
  grep -E "error:|\*\* ARCHIVE FAILED" "$OUT/archive.log" | tail -20 >&2
  exit 1
fi

# Upload straight from the export. manageAppVersionAndBuildNumber=false keeps
# Xcode from changing the build number we cut.
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>74BKX23N3K</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

echo "==> Uploading to App Store Connect (log: $OUT/upload.log)"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
     -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" > "$OUT/upload.log" 2>&1; then
  grep -iE "error|failed" "$OUT/upload.log" | tail -20 >&2
  exit 1
fi
echo "==> Uploaded"

if [ "$DISTRIBUTE" = 1 ]; then
  echo "==> Waiting for processing, then distributing to TestFlight"
  NOTES_ARGS=()
  [ -n "$NOTES_FILE" ] && NOTES_ARGS=(--notes-file "$NOTES_FILE")
  python3 "$HERE/asc.py" distribute --platform "$PLATFORM" --version "$VERSION" --build "$BUILD" \
    ${GROUPS_ARG[@]+"${GROUPS_ARG[@]}"} ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"}
fi
echo "==> Done: $PLATFORM $VERSION ($BUILD)"
