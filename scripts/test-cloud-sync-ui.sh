#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
APPLE_LOCK="${TMPDIR:-/tmp}/ConnDock-Apple-Verification.lock"
mkdir "$APPLE_LOCK" 2>/dev/null || { echo 'Another Apple verification is running.' >&2; exit 1; }
BOOTED_BY_TEST=()
cleanup() {
    for device in "${BOOTED_BY_TEST[@]-}"; do
        if [[ -n "$device" ]]; then xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; fi
    done
    rmdir "$APPLE_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MAC_BUILD_DIR="${MAC_BUILD_DIR:-${TMPDIR:-/tmp}/ConnDock-Phase1-DerivedData}"
IOS_DEVICE="${IOS_DEVICE:-ConnDock iPhone 17}"
IPAD_DEVICE="${IPAD_DEVICE:-ConnDock iPad Pro 11}"
STAMP="$(date +%Y%m%d-%H%M%S)"
COMMON=(-project apple/ConnDock.xcodeproj -configuration Local ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution -collect-test-diagnostics never)
xcodegen generate --spec apple/project.yml
xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_BUILD_DIR" \
    -only-testing:ConnDockUITests-macOS/PhaseZeroUITests/testCloudSyncSettingsStayLocalWithoutSigningAndSupportBothThemes \
    -resultBundlePath "build/phase4-macos-ui-$STAMP.xcresult" test > build/phase4-macos-ui.log 2>&1
for device in "$IOS_DEVICE" "$IPAD_DEVICE"; do
    if xcrun simctl boot "$device" 2>/dev/null; then BOOTED_BY_TEST+=("$device"); fi
    xcrun simctl bootstatus "$device" -b > build/phase4-simulator-boot.log 2>&1
    if [[ "$device" == "$IOS_DEVICE" ]]; then LABEL=iphone; else LABEL=ipad; fi
    xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "platform=iOS Simulator,name=$device" \
        -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
        -only-testing:ConnDockUITests-iOS/PhaseZeroUITests/testCloudSyncSettingsStayLocalWithoutSigningAndSupportBothThemes \
        -resultBundlePath "build/phase4-$LABEL-ui-$STAMP.xcresult" test > "build/phase4-$LABEL-ui.log" 2>&1
    # Do not keep an idle simulator consuming memory while testing the next device.
    for owned in "${BOOTED_BY_TEST[@]-}"; do
        if [[ "$owned" == "$device" ]]; then xcrun simctl shutdown "$device" >/dev/null 2>&1 || true; fi
    done
done
echo "Phase 4 unconfigured/local UI verified on macOS, iPhone, iPad. Results: build/phase4-*-ui-$STAMP.xcresult"
