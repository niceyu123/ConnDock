#!/bin/bash
# Local settings/privacy UI acceptance. Does not use saved hosts or real iCloud.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "${1:-}" in
    '') MAC_SCOPE='ConnDockUITests-macOS/PhaseZeroUITests/testPrivacyVersionAndBackgroundRecovery' ;;
    --mac-full) MAC_SCOPE=ConnDockUITests-macOS ;;
    --help) echo 'Usage: test-phase6-ui.sh [--mac-full]'; exit 0 ;;
    *) echo 'Usage: test-phase6-ui.sh [--mac-full]' >&2; exit 2 ;;
esac
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
MAC_BUILD_DIR="${MAC_BUILD_DIR:-${TMPDIR:-/tmp}/ConnDock-DerivedData}"
IOS_DEVICE="${IOS_DEVICE:-ConnDock iPhone 17}"
IPAD_DEVICE="${IPAD_DEVICE:-ConnDock iPad Pro 11}"
STAMP="$(date +%Y%m%d-%H%M%S)"
COMMON=(-project apple/ConnDock.xcodeproj -configuration Local ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution -collect-test-diagnostics never)
python3 scripts/generate-permission-localizations.py --output apple/Generated/PermissionLocalizations --force
xcodegen generate --spec apple/project.yml
FAILED=0
xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_BUILD_DIR" "-only-testing:$MAC_SCOPE" \
    -resultBundlePath "build/phase6-macos-ui-$STAMP.xcresult" test > build/phase6-macos-ui.log 2>&1 || FAILED=1
for device in "$IOS_DEVICE" "$IPAD_DEVICE"; do
    if xcrun simctl boot "$device" 2>/dev/null; then BOOTED_BY_TEST+=("$device"); fi
    xcrun simctl bootstatus "$device" -b > build/phase6-simulator-boot.log 2>&1
    if [[ "$device" == "$IOS_DEVICE" ]]; then LABEL=iphone; else LABEL=ipad; fi
    xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "platform=iOS Simulator,name=$device" \
        -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
        -only-testing:ConnDockUITests-iOS/PhaseZeroUITests/testPrivacyVersionAndBackgroundRecovery \
        -resultBundlePath "build/phase6-$LABEL-ui-$STAMP.xcresult" test > "build/phase6-$LABEL-ui.log" 2>&1 || FAILED=1
done
[[ "$FAILED" == 0 ]] || { echo 'Phase 6 UI checks failed; all three platforms were attempted.' >&2; exit 1; }
echo "Phase 6 privacy UI verified on macOS, iPhone and iPad: build/phase6-*-ui-$STAMP.xcresult"
