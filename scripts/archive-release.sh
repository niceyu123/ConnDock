#!/bin/bash
# Local archive/export only. No upload, portal mutation or automatic version bump.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
usage() { echo 'Usage: archive-release.sh macos|ios [--unsigned] [--export]'; }
if [[ "${1:-}" == --help ]]; then usage; exit 0; fi
PLATFORM_KIND="${1:-}"
[[ "$PLATFORM_KIND" == macos || "$PLATFORM_KIND" == ios ]] || { usage >&2; exit 2; }
shift
UNSIGNED=0
EXPORT_AFTER=0
for option in "$@"; do
    case "$option" in --unsigned) UNSIGNED=1 ;; --export) EXPORT_AFTER=1 ;; *) usage >&2; exit 2 ;; esac
done
[[ "$UNSIGNED" == 0 || "$EXPORT_AFTER" == 0 ]] || { echo 'An unsigned validation archive cannot be exported for distribution.' >&2; exit 2; }
APPLE_LOCK="${TMPDIR:-/tmp}/ConnDock-Apple-Verification.lock"
mkdir "$APPLE_LOCK" 2>/dev/null || { echo 'Another Apple verification is running.' >&2; exit 1; }
trap 'rmdir "$APPLE_LOCK"' EXIT
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="$ROOT/build/archives/ConnDock-$PLATFORM_KIND-$STAMP.xcarchive"
[[ ! -e "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] || { echo 'Refusing to overwrite an existing archive.' >&2; exit 1; }
mkdir -p "$ROOT/build/archives"
python3 scripts/check-release.py --source-only
scripts/build-xcframework.sh
xcodegen generate --spec apple/project.yml
if [[ "$PLATFORM_KIND" == macos ]]; then
    SCHEME=ConnDock-macOS
    DESTINATION='generic/platform=macOS'
else
    SCHEME=ConnDock-iOS
    DESTINATION='generic/platform=iOS'
fi
ARGS=(-project apple/ConnDock.xcodeproj -scheme "$SCHEME" -configuration Release
    -destination "$DESTINATION" -archivePath "$ARCHIVE_PATH"
    -derivedDataPath "$ROOT/build/Release-DerivedData" ARCHS=arm64
    -skipPackagePluginValidation -disableAutomaticPackageResolution)
if [[ -n "${CONNDOCK_BUILD_NUMBER:-}" ]]; then
    [[ "$CONNDOCK_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'CONNDOCK_BUILD_NUMBER must be a positive integer.' >&2; exit 2; }
    ARGS+=("CURRENT_PROJECT_VERSION=$CONNDOCK_BUILD_NUMBER")
fi
if [[ -n "${CONNDOCK_SIGN_IDENTITY:-}" ]]; then ARGS+=("CODE_SIGN_IDENTITY=$CONNDOCK_SIGN_IDENTITY"); fi
if [[ -n "${CONNDOCK_PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then ARGS+=("PROVISIONING_PROFILE_SPECIFIER=$CONNDOCK_PROVISIONING_PROFILE_SPECIFIER"); fi
if [[ "$UNSIGNED" == 1 ]]; then ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=-); fi
LOG="$ROOT/build/phase6-archive-$PLATFORM_KIND-$STAMP.log"
if ! xcodebuild "${ARGS[@]}" archive > "$LOG" 2>&1; then
    echo "Archive failed; inspect $LOG" >&2
    exit 1
fi
APP="$ARCHIVE_PATH/Products/Applications/ConnDock.app"
APP_EXECUTABLE="$APP/ConnDock"
if [[ "$PLATFORM_KIND" == macos ]]; then APP_EXECUTABLE="$APP/Contents/MacOS/ConnDock"; fi
xcrun swift scripts/check-apple-architectures.swift "$APP_EXECUTABLE"
if [[ "$UNSIGNED" == 1 ]]; then
    echo '{"scope":"unsigned-build-validation","distribution_accepted":false}' > "$ARCHIVE_PATH/ConnDock-Validation.json"
    echo "Unsigned compile-validation archive: $ARCHIVE_PATH (not distributable)"
    exit 0
fi
python3 scripts/check-release.py --mode distribution --app "$APP"
if [[ "$EXPORT_AFTER" == 1 ]]; then
    EXPORT_PATH="$ROOT/build/exports/ConnDock-$PLATFORM_KIND-$STAMP"
    [[ ! -e "$EXPORT_PATH" && ! -L "$EXPORT_PATH" ]] || { echo 'Refusing to overwrite an export.' >&2; exit 1; }
    xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist apple/Release/ExportOptions.plist > "$ROOT/build/phase6-export-$PLATFORM_KIND-$STAMP.log" 2>&1
    echo "Local export: $EXPORT_PATH; nothing uploaded."
else
    echo "Validated archive: $ARCHIVE_PATH; nothing uploaded."
fi
