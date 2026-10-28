#!/bin/bash
# macOS only. Xcode runs this before signing the containing app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
[[ "${PLATFORM_NAME:-}" == macosx ]] || { echo 'MCP helper is macOS-only.' >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$ROOT/build/mcp-target"
cd "$ROOT/rust-core"
cargo build --locked --release --target aarch64-apple-darwin -p conndock-mcp
HELPER_ROOT="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/ConnDockMCP.app"
mkdir -p "$HELPER_ROOT/Contents/MacOS" "$HELPER_ROOT/Contents/Resources"
cp "$ROOT/apple/Privacy/MCPHelper.xcprivacy" "$HELPER_ROOT/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/conndock-mcp" "$HELPER_ROOT/Contents/MacOS/conndock-mcp"
HELPER_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER}.mcp"
/usr/libexec/PlistBuddy -c 'Clear dict' "$HELPER_ROOT/Contents/Info.plist" > /dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleInfoDictionaryVersion string 6.0' "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string conndock-mcp' "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $HELPER_IDENTIFIER" "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string ConnDockMCP' "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${CURRENT_PROJECT_VERSION:-1}" "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${MARKETING_VERSION:-0.1.0}" "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$HELPER_ROOT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$HELPER_ROOT/Contents/Info.plist"
[[ "$(xcrun lipo -archs "$HELPER_ROOT/Contents/MacOS/conndock-mcp")" == arm64 ]] || { echo 'MCP helper must contain arm64 only.' >&2; exit 1; }
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
    [[ -n "$IDENTITY" ]] || IDENTITY=-
    ARGS=(--force --sign "$IDENTITY" --timestamp=none)
    if [[ "${CONFIGURATION:-}" != Local ]]; then
        ARGS+=(--options runtime --entitlements "$ROOT/apple/Apps/macOS/MCPHelper.entitlements")
    fi
    codesign "${ARGS[@]}" "$HELPER_ROOT"
    codesign --verify --strict "$HELPER_ROOT"
fi
