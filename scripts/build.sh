#!/bin/bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT"
LOCAL=0
case "${1:-}" in
    "") ;;
    --with-local-collector) LOCAL=1 ;;
    *) printf 'Usage: %s [--with-local-collector]\n' "$0" >&2; exit 2 ;;
esac
VERSION=$(cat VERSION)
BUILD=$(cat BUILD_NUMBER)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || exit 2
OUTPUT="$PROJECT/build"
if [[ $LOCAL -eq 1 ]]; then OUTPUT="$PROJECT/build-local"; fi
APP="$OUTPUT/DriveThermal.app"
mkdir -p "$OUTPUT"
STAGE=$(mktemp -d "$OUTPUT/.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/DriveThermal.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
./scripts/test.sh
if [[ $LOCAL -eq 1 ]]; then
    [[ -f collector/src/rtl9210_health_probe.m ]] || { echo 'Local collector not installed; see docs/COLLECTOR.md.' >&2; exit 1; }
    mkdir -p collector/.build
    bash -n collector/rtl9210-health collector/scripts/macos-sudo-askpass
    shellcheck collector/rtl9210-health collector/scripts/macos-sudo-askpass
    xcrun clang -Wall -Wextra -Werror collector/tests/usb_layout.c -o .build/test-layout
    .build/test-layout
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
        -framework Foundation -framework IOKit -framework IOUSBHost \
        collector/src/rtl9210_health_probe.m -o collector/.build/rtl9210_health_probe
    rsync -a --exclude AGENTS.md --exclude runs --exclude latest --exclude device.plist \
        collector/ "$BUNDLE/Contents/Resources/collector/"
    codesign --force --sign - "$BUNDLE/Contents/Resources/collector/.build/rtl9210_health_probe"
    PACKAGE="$BUNDLE/Contents/Resources/ServicePackage"
    mkdir -p "$PACKAGE"
    cp -R "$BUNDLE/Contents/Resources/collector" "$PACKAGE/collector"
    xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
        Sources/Health.swift Sources/ServiceProtocol.swift Service/main.swift -o "$PACKAGE/DriveThermalService"
    xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
        Sources/Health.swift Sources/ServiceProtocol.swift Service/Installer.swift -o "$PACKAGE/DriveThermalInstaller"
    codesign --force --sign - "$PACKAGE/DriveThermalService"
    codesign --force --sign - "$PACKAGE/DriveThermalInstaller"
fi
ARCH=$(uname -m)
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos14.0" -module-cache-path .build/module-cache \
    -framework AppKit -framework SwiftUI Sources/Health.swift Sources/Diagnostics.swift Sources/ServiceProtocol.swift Sources/ServiceClient.swift Sources/App.swift \
    -o "$BUNDLE/Contents/MacOS/DriveThermal"
REVISION=$(git rev-parse --short HEAD 2>/dev/null || printf uncommitted)
if ! git diff --quiet 2>/dev/null; then REVISION="$REVISION-dirty"; fi
BUILT_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
python3 - "$BUNDLE" "$VERSION" "$BUILD" "$REVISION" "$BUILT_AT" "$LOCAL" <<'PY'
import plistlib,sys
from pathlib import Path
bundle,version,build,revision,built_at,local=sys.argv[1:]
info={'CFBundleExecutable':'DriveThermal','CFBundleIdentifier':'local.drivethermal.app',
      'CFBundleName':'DriveThermal','CFBundlePackageType':'APPL',
      'CFBundleShortVersionString':version,'CFBundleVersion':build,
      'LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSHighResolutionCapable':True,
      'DTBuildRevision':revision,'DTBuildDate':built_at,'DTBundledCollector':local=='1',
      'NSRemovableVolumesUsageDescription':'用于检查已登记外置硬盘的占用状态，安全采集健康信息及挂载／卸载宗卷。不会上传硬盘文件。',
      'NSHumanReadableCopyright':'Copyright © 2026 dff652. UI and integration interface: MIT.'}
with (Path(bundle)/'Contents/Info.plist').open('wb') as f: plistlib.dump(info,f)
PY
cp LICENSE "$BUNDLE/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.txt"
codesign --force --sign - "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
# Only replace this script's generated app, never user state or enrolled devices.
if [[ -e "$APP" ]]; then rm -rf "$APP"; fi
mv "$BUNDLE" "$APP"
printf 'Built %s (collector bundled: %s)\n' "$APP" "$LOCAL"
