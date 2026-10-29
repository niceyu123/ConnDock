#!/bin/bash
# Run after build-xcframework.sh; credentials remain in temporary sandbox files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
AUTH_METHOD="${CONNDOCK_TEST_AUTH_METHOD:-ed25519}"
TEST_METHOD="${CONNDOCK_TEST_METHOD:-testRealSSHThroughNativeTerminal}"
PHASE="${CONNDOCK_TEST_PHASE:-phase1}"
PLATFORM="${CONNDOCK_TEST_PLATFORM:-all}"
[[ "$PLATFORM" == all || "$PLATFORM" == macos ]] || { echo 'Unsupported test platform' >&2; exit 1; }
[[ "$PHASE" == phase1 || "$PHASE" == phase2 || "$PHASE" == phase3 || "$PHASE" == phase5 || "$PHASE" == phase6 || "$PHASE" == phase8 ]] || { echo 'Unsupported test phase' >&2; exit 1; }
[[ "$TEST_METHOD" == testRealSSHThroughNativeTerminal || "$TEST_METHOD" == testSavedHostsUseKeychainAndSwitchLiveSessions || "$TEST_METHOD" == testRealSSHConnectionFormAndScreenshots || "$TEST_METHOD" == testSFTPAndLinuxMonitorThroughBridge || "$TEST_METHOD" == testMCPThroughHelperAndRealSSH || "$TEST_METHOD" == testSessionLifecycleRecoveryAndRepeatedTabs || "$TEST_METHOD" == testAdvancedTransportThroughBridge || "$TEST_METHOD" == testAgentConnectionThroughForm ]] || { echo 'Unsupported test method' >&2; exit 1; }
if [[ "$TEST_METHOD" == testAdvancedTransportThroughBridge ]]; then
    [[ "$PHASE" == phase8 && "${CONNDOCK_TEST_ISOLATED:-}" == 1 && "${CONNDOCK_TEST_HOST:-}" == 127.0.0.1 ]] || { echo 'Advanced connection verification requires an isolated loopback fixture.' >&2; exit 1; }
fi
if [[ "$TEST_METHOD" == testSessionLifecycleRecoveryAndRepeatedTabs ]]; then
    [[ "$PHASE" == phase6 && "${CONNDOCK_TEST_ISOLATED:-}" == 1 && "${CONNDOCK_TEST_HOST:-}" == 127.0.0.1 ]] || { echo 'Stability verification requires the isolated loopback fixture.' >&2; exit 1; }
fi
if [[ "$TEST_METHOD" == testMCPThroughHelperAndRealSSH ]]; then
    [[ "$PHASE" == phase5 && "$PLATFORM" == macos && "${CONNDOCK_TEST_ISOLATED:-}" == 1 && "${CONNDOCK_TEST_HOST:-}" == 127.0.0.1 && -n "${CONNDOCK_TEST_WORK_DIRECTORY:-}" ]] || { echo 'MCP verification requires the isolated loopback fixture and macOS.' >&2; exit 1; }
fi
if [[ "$TEST_METHOD" == testSFTPAndLinuxMonitorThroughBridge ]]; then
    [[ "$PHASE" == phase3 && "${CONNDOCK_TEST_ISOLATED:-}" == 1 && "${CONNDOCK_TEST_HOST:-}" == 127.0.0.1 && -n "${CONNDOCK_TEST_WORK_DIRECTORY:-}" ]] || { echo 'Phase 3 write verification requires the isolated loopback fixture.' >&2; exit 1; }
fi
if [[ "$TEST_METHOD" == testRealSSHConnectionFormAndScreenshots || "$TEST_METHOD" == testAgentConnectionThroughForm ]]; then
    [[ "$PLATFORM" == macos && "$AUTH_METHOD" == ed25519 && "${CONNDOCK_TEST_HOST:-}" == 127.0.0.1 && -n "${CONNDOCK_TEST_WORK_DIRECTORY:-}" ]] || { echo 'UI SSH verification requires the isolated local fixture and macOS.' >&2; exit 1; }
fi
if [[ "$AUTH_METHOD" == password ]]; then AUTH_FILE_NAME=CONNDOCK_TEST_PASSWORD_FILE
elif [[ "$AUTH_METHOD" == ed25519 ]]; then AUTH_FILE_NAME=CONNDOCK_TEST_KEY_FILE
else echo 'Unsupported CONNDOCK_TEST_AUTH_METHOD' >&2; exit 1; fi
export CONNDOCK_TEST_AUTH_METHOD="$AUTH_METHOD"
for name in CONNDOCK_TEST_HOST CONNDOCK_TEST_PORT CONNDOCK_TEST_USER CONNDOCK_TEST_FINGERPRINT "$AUTH_FILE_NAME"; do
    [[ -n "${!name:-}" ]] || { echo "Missing $name" >&2; exit 1; }
done
COMMON=(-project apple/ConnDock.xcodeproj -configuration Local ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution -collect-test-diagnostics never)
MAC_BUILD_DIR="${MAC_BUILD_DIR:-${TMPDIR:-/tmp}/ConnDock-DerivedData}"
APPLE_LOCK="${TMPDIR:-/tmp}/ConnDock-Apple-Verification.lock"
mkdir "$APPLE_LOCK" 2>/dev/null || { echo 'Another Apple verification is running; run these checks sequentially.' >&2; exit 1; }
IOS_DEVICE="${IOS_DEVICE:-ConnDock iPhone 17}"
IPAD_DEVICE="${IPAD_DEVICE:-ConnDock iPad Pro 11}"
CONFIG_FILES=()
CONFIG_DIRECTORIES=()
CONFIG_DEVICES=()
export CONNDOCK_TEST_RUN_ID="$(uuidgen)"
remove_configuration() {
    python3 - "$1" <<'PY'
import json,os,sys
from pathlib import Path
p=Path(sys.argv[1])
if p.is_file():
    try: owned=json.loads(p.read_text()).get('runIdentifier') == os.environ['CONNDOCK_TEST_RUN_ID']
    except (ValueError,OSError): owned=False
    if owned:p.unlink()
PY
}
cleanup() {
    for path in "${CONFIG_FILES[@]-}"; do
        if [[ -n "$path" ]]; then remove_configuration "$path"; fi
    done
    for directory in "${CONFIG_DIRECTORIES[@]-}"; do
        if [[ -n "$directory" ]]; then rmdir "$directory"; fi
    done
    # Xcode may migrate simulator Documents to a new data-container UUID.
    for device in "${CONFIG_DEVICES[@]-}"; do
        if [[ -n "$device" ]]; then
            container="$(xcrun simctl get_app_container "$device" local.SSHClient.iOS data 2>/dev/null || true)"
            if [[ -n "$container" ]]; then remove_configuration "$container/Documents/ConnDockIntegration.json"; fi
        fi
    done
    rmdir "$APPLE_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

install_configuration() {
    local target="$1/ConnDockIntegration.json"
    # Refuse to overwrite a pre-existing file, including one from another run.
    python3 - "$target" <<'PY'
import json,os,sys
from pathlib import Path
config=dict(host=os.environ['CONNDOCK_TEST_HOST'],port=int(os.environ['CONNDOCK_TEST_PORT']),
            username=os.environ['CONNDOCK_TEST_USER'],fingerprint=os.environ['CONNDOCK_TEST_FINGERPRINT'],
            workingDirectory=os.environ.get('CONNDOCK_TEST_WORK_DIRECTORY'),
            expectLinux=os.environ.get('CONNDOCK_TEST_EXPECT_LINUX')=='1',
            isolatedFixture=os.environ.get('CONNDOCK_TEST_ISOLATED')=='1',
            runCodex=os.environ.get('CONNDOCK_TEST_MCP_CODEX')=='1',
            runIdentifier=os.environ['CONNDOCK_TEST_RUN_ID'],
            captureScreenshots=os.environ.get('CONNDOCK_TEST_CAPTURE_SCREENSHOTS','1')=='1')
if os.environ.get('CONNDOCK_TEST_PHASE')=='phase8':
    config['agentSocket']=os.environ.get('SSH_AUTH_SOCK')
    config['agentFingerprint']=os.environ.get('CONNDOCK_TEST_AGENT_FINGERPRINT')
    config['targetPort']=int(os.environ.get('CONNDOCK_TEST_TARGET_PORT','22'))
if os.environ['CONNDOCK_TEST_AUTH_METHOD']=='password':
    config['password']=Path(os.environ['CONNDOCK_TEST_PASSWORD_FILE']).read_text().rstrip('\r\n')
else:
    config['privateKey']=Path(os.environ['CONNDOCK_TEST_KEY_FILE']).read_text()
    if os.environ.get('CONNDOCK_TEST_PASSPHRASE_FILE'):
        config['passphrase']=Path(os.environ['CONNDOCK_TEST_PASSPHRASE_FILE']).read_text().rstrip('\r\n')
target=Path(sys.argv[1]);target.parent.mkdir(parents=True,exist_ok=True)
fd=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:json.dump(config,f)
PY
    CONFIG_FILES+=("$target")
}

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ "${CONNDOCK_TEST_REBUILD_BRIDGE:-}" == 1 ]]; then scripts/build-xcframework.sh; fi
xcodegen generate --spec apple/project.yml
if [[ "$TEST_METHOD" == testRealSSHConnectionFormAndScreenshots || "$TEST_METHOD" == testAgentConnectionThroughForm ]]; then
    # Keep runner-owned one-shot input outside protected Documents paths.
    UI_CONFIG_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ConnDock-UI-SSH.XXXXXX")"
    chmod 700 "$UI_CONFIG_DIRECTORY"
    CONFIG_DIRECTORIES+=("$UI_CONFIG_DIRECTORY")
    UI_CONFIG="$UI_CONFIG_DIRECTORY/ConnDockIntegration.json"
    python3 - "$UI_CONFIG" <<'PY'
import json,os,sys
config=dict(host=os.environ['CONNDOCK_TEST_HOST'],port=int(os.environ['CONNDOCK_TEST_PORT']),
            username=os.environ['CONNDOCK_TEST_USER'],fingerprint=os.environ['CONNDOCK_TEST_FINGERPRINT'],
            privateKeyPath=os.environ['CONNDOCK_TEST_KEY_FILE'],workingDirectory=os.environ['CONNDOCK_TEST_WORK_DIRECTORY'],
            phase=os.environ.get('CONNDOCK_TEST_PHASE','phase1'),
            expectLinux=os.environ.get('CONNDOCK_TEST_EXPECT_LINUX')=='1',
            uploadFilePath=os.environ.get('CONNDOCK_TEST_UI_UPLOAD_FILE'),
            exportDirectoryPath=os.environ.get('CONNDOCK_TEST_UI_EXPORT_DIRECTORY'),
            runIdentifier=os.environ['CONNDOCK_TEST_RUN_ID'],
            agentSocket=os.environ.get('SSH_AUTH_SOCK'),agentFingerprint=os.environ.get('CONNDOCK_TEST_AGENT_FINGERPRINT'))
fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f:json.dump(config,f)
PY
    CONFIG_FILES+=("$UI_CONFIG")
    TEST_RUNNER_CONNDOCK_UI_SSH_CONFIGURATION="$UI_CONFIG" xcodebuild "${COMMON[@]}" \
        -scheme ConnDock-macOS -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_BUILD_DIR" \
        "-only-testing:ConnDockUITests-macOS/PhaseZeroUITests/$TEST_METHOD" \
        -resultBundlePath "build/$PHASE-mac-ui-ssh-$STAMP.xcresult" test > "build/$PHASE-mac-ui-ssh.log" 2>&1
    echo "Real SSH UI verification finished. Result: build/$PHASE-mac-ui-ssh-$STAMP.xcresult"
    exit
fi
xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_BUILD_DIR" -only-testing:ConnDockTests-macOS build-for-testing > "build/$PHASE-mac-test-build.log" 2>&1
install_configuration "$HOME/Library/Containers/local.SSHClient.macOS/Data/Documents"
xcodebuild "${COMMON[@]}" -scheme ConnDock-macOS -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_BUILD_DIR" "-only-testing:ConnDockTests-macOS/SSHIntegrationTests/$TEST_METHOD" \
    -resultBundlePath "build/$PHASE-mac-ssh-$STAMP.xcresult" test-without-building > "build/$PHASE-mac-ssh.log" 2>&1
if [[ "$PLATFORM" == macos ]]; then
    echo "Real SSH integration finished on macOS. Result: build/$PHASE-mac-ssh-$STAMP.xcresult"
    exit
fi

xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "platform=iOS Simulator,name=$IOS_DEVICE" \
    -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES -only-testing:ConnDockTests-iOS build-for-testing > "build/$PHASE-ios-test-build.log" 2>&1
for device in "$IOS_DEVICE" "$IPAD_DEVICE"; do
    xcrun simctl boot "$device" 2>/dev/null || true
    xcrun simctl bootstatus "$device" -b > "build/$PHASE-simulator-boot.log" 2>&1
    xcrun simctl install "$device" build/iOS/Build/Products/Local-iphonesimulator/ConnDock.app
    CONTAINER="$(xcrun simctl get_app_container "$device" local.SSHClient.iOS data)"
    install_configuration "$CONTAINER/Documents"
    CONFIG_DEVICES+=("$device")
    if [[ "$device" == "$IOS_DEVICE" ]]; then LABEL=iphone; else LABEL=ipad; fi
    xcodebuild "${COMMON[@]}" -scheme ConnDock-iOS -destination "platform=iOS Simulator,name=$device" \
        -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES "-only-testing:ConnDockTests-iOS/SSHIntegrationTests/$TEST_METHOD" \
        -resultBundlePath "build/$PHASE-$LABEL-ssh-$STAMP.xcresult" test-without-building > "build/$PHASE-$LABEL-ssh.log" 2>&1
done
echo "Real SSH → Rust → UniFFI → SwiftTerm integration finished on macOS, iPhone and iPad. Results: build/$PHASE-*-ssh-*.xcresult"
