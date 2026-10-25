#!/bin/bash
# Remove the simulator clones xcodebuild leaves behind.
#
# With parallel testing on, `xcodebuild test` runs on a clone of the simulator
# ("Clone 2 of iPhone 17") in ~/Library/Developer/XCTestDevices and Xcode 27
# does not always delete it afterwards: 93 clones (~4 GB each) had piled up by
# 2026-10-25. The schemes and the documented test commands now run on the
# booted device (parallel testing off); this sweeps whatever an interrupted or
# older run still left. Skips while a test is running. Safe: Xcode recreates
# clones on demand.
set -u
SET="$HOME/Library/Developer/XCTestDevices"
if pgrep -qf "xcodebuild"; then
    echo "sweep: xcodebuild is running, leaving the simulator clones alone"
    exit 0
fi
n=$(xcrun simctl --set "$SET" list devices 2>/dev/null | grep -c "Clone")
if [ "$n" -eq 0 ]; then
    echo "sweep: no leftover simulator clones"
    exit 0
fi
before=$(df -g / | awk 'NR==2{print $4}')
xcrun simctl --set "$SET" delete all >/dev/null 2>&1
after=$(df -g / | awk 'NR==2{print $4}')
echo "sweep: deleted $n leftover simulator clone(s); free space $before -> $after GB"
