#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cd "$ROOT/rust-core"
for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
    cargo build --locked --release -p conndock-apple-ffi --lib --target "$target"
done
