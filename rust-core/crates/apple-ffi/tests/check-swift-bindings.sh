#!/bin/bash
# Generate bindings from the built library and compile the real Swift API consumer.
set -euo pipefail
CRATE_DIRECTORY="$(cd "$(dirname "$0")/.." && pwd)"
RUST_WORKSPACE="$(cd "$CRATE_DIRECTORY/../.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
CHECK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/conndock-bindings-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIRECTORY"' EXIT
cd "$RUST_WORKSPACE"
cargo build --locked -p conndock-apple-ffi --features bindgen --lib --bin uniffi-bindgen
target/debug/uniffi-bindgen generate --library target/debug/libconndock_ffi.dylib \
    --language swift --out-dir "$CHECK_DIRECTORY"
xcrun swiftc -typecheck -swift-version 6 -parse-as-library -module-name SSHCoreBridge \
    -I "$CHECK_DIRECTORY" -module-cache-path "$CHECK_DIRECTORY/ModuleCache" \
    -Xcc "-fmodule-map-file=$CHECK_DIRECTORY/ConnDockFFI.modulemap" \
    "$CHECK_DIRECTORY/SSHCoreBridge.swift" "$CRATE_DIRECTORY/tests/Phase5Exports.swift"
echo 'Generated Swift Phase 5 exports typecheck passed.'
