#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/generate-permission-localizations.py" --output "$ROOT/apple/Generated/PermissionLocalizations" --force
"$ROOT/scripts/build-rust-apple.sh"
"$ROOT/scripts/generate-bindings.sh"
STAGING="$ROOT/build/xcframework"
mkdir -p "$STAGING/headers" "$STAGING/macos"
cp "$ROOT/build/bindings/ConnDockFFI.h" "$STAGING/headers/"
cp "$ROOT/build/bindings/ConnDockFFI.modulemap" "$STAGING/headers/module.modulemap"
cp "$ROOT/rust-core/target/aarch64-apple-darwin/release/libconndock_ffi.a" "$STAGING/macos/libconndock_ffi.a"
[[ "$(xcrun lipo -archs "$STAGING/macos/libconndock_ffi.a")" == arm64 ]] || { echo 'macOS library must contain arm64 only.' >&2; exit 1; }
OUTPUT="$ROOT/apple/Packages/SSHCoreBridge/Artifacts/ConnDockFFI.xcframework"
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
    -library "$STAGING/macos/libconndock_ffi.a" -headers "$STAGING/headers" \
    -library "$ROOT/rust-core/target/aarch64-apple-ios/release/libconndock_ffi.a" -headers "$STAGING/headers" \
    -library "$ROOT/rust-core/target/aarch64-apple-ios-sim/release/libconndock_ffi.a" -headers "$STAGING/headers" \
    -output "$OUTPUT"
