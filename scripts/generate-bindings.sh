#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
cd "$ROOT/rust-core"
cargo build --locked --release -p conndock-apple-ffi --features bindgen --lib --bin uniffi-bindgen
OUTPUT="$ROOT/build/bindings"
mkdir -p "$OUTPUT"
target/release/uniffi-bindgen generate --library target/release/libconndock_ffi.dylib --language swift \
    --out-dir "$OUTPUT"
DEST="$ROOT/apple/Packages/SSHCoreBridge/Sources/SSHCoreBridge/Generated"
mkdir -p "$DEST"
cp "$OUTPUT/SSHCoreBridge.swift" "$DEST/SSHCoreBridge.swift"
