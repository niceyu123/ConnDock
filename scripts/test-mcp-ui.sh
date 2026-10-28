#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APPLE_LOCK="${TMPDIR:-/tmp}/ConnDock-Apple-Verification.lock"
mkdir "$APPLE_LOCK" 2>/dev/null || { echo 'Another Apple verification is running.' >&2; exit 1; }
trap 'rmdir "$APPLE_LOCK"' EXIT
MAC_BUILD_DIR="${MAC_BUILD_DIR:-${TMPDIR:-/tmp}/ConnDock-DerivedData}"
STAMP="$(date +%Y%m%d-%H%M%S)"
xcodebuild -project apple/ConnDock.xcodeproj -scheme ConnDock-macOS -configuration Local \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_BUILD_DIR" \
    ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation \
    -disableAutomaticPackageResolution -collect-test-diagnostics never \
    -only-testing:ConnDockUITests-macOS/PhaseZeroUITests/testMCPSettingsPermissionsAndLocalizedAppearance \
    -resultBundlePath "build/phase5-mcp-ui-$STAMP.xcresult" test > build/phase5-mcp-ui.log 2>&1
