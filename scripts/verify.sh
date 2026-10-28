#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
cd "$ROOT"
mkdir -p build
APPLE_LOCK="${TMPDIR:-/tmp}/ConnDock-Apple-Verification.lock"
mkdir "$APPLE_LOCK" 2>/dev/null || { echo 'Another Apple verification is running; run these checks sequentially.' >&2; exit 1; }
trap 'rmdir "$APPLE_LOCK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MAC_BUILD_DIR="${MAC_BUILD_DIR:-${TMPDIR:-/tmp}/ConnDock-DerivedData}"
command -v cargo >/dev/null
command -v xcodegen >/dev/null
xcodebuild -version
cargo --version
git diff --check
xcrun swift-format lint --strict --recursive apple/Shared apple/Features apple/Apps apple/Tests apple/UITests \
    apple/Package.swift apple/Packages/SSHCoreBridge/Package.swift \
    apple/Packages/SSHCoreBridge/Sources/SSHCoreBridge/BridgeProbe.swift scripts/*.swift
xcrun swift scripts/check-localizations.swift
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
python3 scripts/check-release.py --source-only
python3 scripts/generate-permission-localizations.py --output apple/Generated/PermissionLocalizations --force
cd rust-core
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
cd "$ROOT"
rust-core/crates/apple-ffi/tests/check-swift-bindings.sh
scripts/build-xcframework.sh
xcodegen generate --spec apple/project.yml

# SwiftTerm 1.19.0 has a build-info generator. Its pinned source is reviewed;
# this per-command flag permits the plugin without changing global Xcode trust.
# Keep test logs, assertions, and screenshot attachments. Avoid collecting an
# entire simulator sysdiagnose on failure; that can stall result export for minutes.
COMMON=(-project apple/ConnDock.xcodeproj -configuration Local ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution -collect-test-diagnostics never)
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
IPAD_DESTINATION="${IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 11-inch (M5)}"
MAC_DESTINATION="${MAC_DESTINATION:-platform=macOS,arch=arm64}"

xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination "$MAC_DESTINATION" \
    -derivedDataPath "$MAC_BUILD_DIR" build > build/macos-build.log 2>&1
xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build > build/ios-build.log 2>&1
xcrun swift scripts/check-apple-architectures.swift \
    "$MAC_BUILD_DIR/Build/Products/Local/ConnDock.app/Contents/MacOS/ConnDock" \
    "$ROOT/build/iOS/Build/Products/Local-iphonesimulator/ConnDock.app/ConnDock"

python3 scripts/check-release.py --mode local --app "$MAC_BUILD_DIR/Build/Products/Local/ConnDock.app"
python3 scripts/check-release.py --mode local --app "$ROOT/build/iOS/Build/Products/Local-iphonesimulator/ConnDock.app"

STAMP="$(date +%Y%m%d-%H%M%S)"
xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination "$MAC_DESTINATION" \
    -derivedDataPath "$MAC_BUILD_DIR" -only-testing:ConnDockTests-macOS \
    -resultBundlePath "build/macOS-unit-$STAMP.xcresult" test > build/macos-unit.log 2>&1
xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "$IOS_DESTINATION" \
    -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:ConnDockTests-iOS \
    -resultBundlePath "build/iOS-unit-$STAMP.xcresult" test > build/ios-unit.log 2>&1

if [[ "${1:-}" == "--ui" ]]; then
    UI_FAILED=0
    xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination "$MAC_DESTINATION" \
        -derivedDataPath "$MAC_BUILD_DIR" -only-testing:ConnDockUITests-macOS \
        -resultBundlePath "build/macOS-ui-$STAMP.xcresult" test > build/macos-ui.log 2>&1 || UI_FAILED=1
    xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "$IOS_DESTINATION" \
        -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:ConnDockUITests-iOS \
        -resultBundlePath "build/iPhone-ui-$STAMP.xcresult" test > build/iphone-ui.log 2>&1 || UI_FAILED=1
    xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "$IPAD_DESTINATION" \
        -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:ConnDockUITests-iOS \
        -resultBundlePath "build/iPad-ui-$STAMP.xcresult" test > build/ipad-ui.log 2>&1 || UI_FAILED=1
    if [[ "$UI_FAILED" != 0 ]]; then
        echo 'UI verification failed. All three platforms were attempted; inspect build/*-ui.log and xcresult bundles.' >&2
        exit 1
    fi
fi
git diff --check
echo 'Verification completed. Logs and xcresult bundles: build/'
