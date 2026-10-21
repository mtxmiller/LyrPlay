#!/bin/bash
# LyrPlay playback smoke harness (v0) — boots an iOS simulator, installs the
# app preconfigured for the test LMS server, launches it, and runs the
# JSON-RPC oracle scenarios in smoke.py.
#
# Spec: docs/playback-smoke-harness.md (bd epic LMS_StreamTest-6b1).
#
#   scripts/smoke/run.sh             # all scenarios
#   scripts/smoke/run.sh S1 S5       # subset
#
# Env overrides:
#   LYRPLAY_LMS_HOST   (192.168.1.8)   LYRPLAY_LMS_PORT  (9010, lms-test)
#   LYRPLAY_SLIM_PORT  (3490, lms-test) LYRPLAY_SIM_NAME  (iPhone 17 — must
#                                      exist on the LATEST installed runtime)
#   LYRPLAY_PLAYER_NAME (SmokeTest Player)
#   LYRPLAY_APP_WEB_PORT / LYRPLAY_APP_SLIM_PORT   ports the APP is given
#                      (default: the LMS ports). Set 9011 / 3491 to send the
#                      app through faultproxy.py; the oracle stays on the LMS.
#   LYRPLAY_LAUNCH_ARGS  extra app launch arguments, e.g. "-SeamlessReconnect NO"
#   LYRPLAY_APP_PATH   prebuilt .app — skips the xcodebuild step
#
# The Debug build is cached in build/smoke-derived-data; delete it to force
# a rebuild after app-code changes.
set -euo pipefail

LMS_HOST="${LYRPLAY_LMS_HOST:-192.168.1.8}"
LMS_PORT="${LYRPLAY_LMS_PORT:-9010}"
SLIM_PORT="${LYRPLAY_SLIM_PORT:-3490}"
APP_WEB_PORT="${LYRPLAY_APP_WEB_PORT:-$LMS_PORT}"
APP_SLIM_PORT="${LYRPLAY_APP_SLIM_PORT:-$SLIM_PORT}"
SIM_NAME="${LYRPLAY_SIM_NAME:-iPhone 17}"
PLAYER_NAME="${LYRPLAY_PLAYER_NAME:-SmokeTest Player}"
BUNDLE_ID="elm.LMS-StreamTest"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# DerivedData must live OUTSIDE the repo: the repo sits under Documents/, where
# iCloud adds Finder metadata to new files and codesign then rejects the
# embedded frameworks ("resource fork ... detritus not allowed").
DD="${LYRPLAY_SMOKE_DD:-$HOME/Library/Developer/Xcode/DerivedData/LyrPlay-smoke}"
APP="${LYRPLAY_APP_PATH:-$DD/Build/Products/Debug-iphonesimulator/LMS_StreamTest.app}"

echo "== LyrPlay smoke harness: $SIM_NAME vs LMS $LMS_HOST:$LMS_PORT =="

# 1. Build the app — ALWAYS (incremental via cached DerivedData, so cheap when
#    nothing changed). Skipping on .app existence would certify a stale binary,
#    the worst failure mode for a harness gating fix loops. LYRPLAY_APP_PATH
#    opts out for prebuilt bundles.
if [ -z "${LYRPLAY_APP_PATH:-}" ]; then
  echo "-- building LMS_StreamTest (Debug, simulator)..."
  BUILD_LOG="$(mktemp -t lyrplay-smoke-build)"
  if ! xcodebuild -workspace "$ROOT/LMS_StreamTest.xcworkspace" -scheme LMS_StreamTest \
      -configuration Debug -destination "platform=iOS Simulator,name=$SIM_NAME" \
      -derivedDataPath "$DD" build > "$BUILD_LOG" 2>&1; then
    echo "-- BUILD FAILED ($BUILD_LOG):"
    grep -m 8 "error:" "$BUILD_LOG" || tail -15 "$BUILD_LOG"
    exit 1
  fi
fi
[ -d "$APP" ] || { echo "app bundle not found at $APP"; exit 1; }

# 2. Boot the simulator
# Prefer the NEWEST runtime when the same device name exists on several —
# xcodebuild's implicit OS:latest resolves the same way, keeping build and
# boot on the same runtime.
UDID=$(xcrun simctl list -j devices available | SIM_NAME="$SIM_NAME" python3 -c "
import json, os, sys
data = json.load(sys.stdin)
matches = [
    (runtime, dev['udid'])
    for runtime, devs in data['devices'].items()
    for dev in devs
    if dev['name'] == os.environ['SIM_NAME']
]
if not matches:
    sys.exit('no available simulator named ' + os.environ['SIM_NAME'])
print(max(matches)[1])
")
echo "-- simulator: $SIM_NAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b >/dev/null

# 3. Install, then pre-seed UserDefaults so the app skips onboarding and
#    connects straight to the test server. Keys/types must match
#    SettingsManager.Keys. The values go in the app's own data container: a
#    plain `defaults write <bundle id>` lands in the simulator-wide domain,
#    which the app does not read once its container plist exists.
xcrun simctl install "$UDID" "$APP"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
PREFS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Library/Preferences/$BUNDLE_ID"
seed() { xcrun simctl spawn "$UDID" defaults write "$PREFS" "$@"; }
seed ServerHost -string "$LMS_HOST"
seed ServerWebPort -int "$APP_WEB_PORT"
seed ServerSlimProtoPort -int "$APP_SLIM_PORT"
seed PlayerName -string "$PLAYER_NAME"
# SettingsVersion deliberately NOT seeded: absent (0) is the app's benign
# first-launch path; a hardcoded literal would silently diverge when the app
# bumps currentSettingsVersion.
seed IsConfigured -bool YES

# 4. Fresh launch
# shellcheck disable=SC2086  # word-splitting the args is the point
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${LYRPLAY_LAUNCH_ARGS:-} >/dev/null
echo "-- app launched, running scenarios"

# 5. Oracle scenarios (exit code propagates)
LYRPLAY_LMS_HOST="$LMS_HOST" LYRPLAY_LMS_PORT="$LMS_PORT" \
LYRPLAY_PLAYER_NAME="$PLAYER_NAME" \
  python3 "$ROOT/scripts/smoke/smoke.py" "$@"
