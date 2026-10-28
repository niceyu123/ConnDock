#!/bin/bash
# Bounded real-SSH resource and lifecycle checks; never connects to saved hosts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-}"
case "$MODE" in
    ''|--rust-only|--apple-only) ;;
    --help) echo 'Usage: test-stability.sh [--rust-only|--apple-only]'; exit 0 ;;
    *) echo 'Usage: test-stability.sh [--rust-only|--apple-only]' >&2; exit 2 ;;
esac
mkdir -p build
if [[ "$MODE" != --apple-only ]]; then
    scripts/test-linux-services.sh --stability > build/phase6-stability-rust.log 2>&1
    echo 'Real Rust multi-session stability results: build/phase6-stability-rust.log'
fi
if [[ "$MODE" != --rust-only ]]; then
    CONNDOCK_TEST_PHASE=phase6 CONNDOCK_TEST_METHOD=testSessionLifecycleRecoveryAndRepeatedTabs \
        CONNDOCK_TEST_CAPTURE_SCREENSHOTS=0 CONNDOCK_TEST_REBUILD_BRIDGE=1 \
        scripts/test-linux-services.sh --apple-only
fi
