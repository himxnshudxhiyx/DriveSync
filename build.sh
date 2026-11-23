#!/bin/bash
# Builds DriveSync.app (universal: Apple Silicon + Intel).
#   ./build.sh install   also copies it to /Applications and launches it
#   ./build.sh dmg       also packages build/DriveSync.dmg (drag-to-Applications installer)
set -euo pipefail
cd "$(dirname "$0")"

[ -f google.env ] || { echo "Missing google.env. See README → 'Google Cloud setup'."; exit 1; }
source google.env
: "${GOOGLE_CLIENT_ID:?set GOOGLE_CLIENT_ID in google.env}"
: "${GOOGLE_CLIENT_SECRET:?set GOOGLE_CLIENT_SECRET in google.env}"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/DriveSync"
APP=build/DriveSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s|__CLIENT_ID__|$GOOGLE_CLIENT_ID|" -e "s|__CLIENT_SECRET__|$GOOGLE_CLIENT_SECRET|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
# Finder Sync extension (per-file badges). App extensions must be sandboxed; sign it before the app.
EXT="$APP/Contents/PlugIns/DriveSyncFinder.appex"
mkdir -p "$EXT/Contents/MacOS"
SDK="$(xcrun --show-sdk-path)"
for a in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -application-extension -module-name DriveSyncFinder -sdk "$SDK" \
        -target "$a-apple-macos14.0" -Xlinker -e -Xlinker _NSExtensionMain Extension/FinderSync.swift -o "build/finder-$a"
done
lipo -create build/finder-arm64 build/finder-x86_64 -output "$EXT/Contents/MacOS/DriveSyncFinder"
rm build/finder-arm64 build/finder-x86_64
cp Resources/FinderInfo.plist "$EXT/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Finder.entitlements "$EXT"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = install ]; then
    pkill -x DriveSync || true
    rm -rf /Applications/DriveSync.app
    cp -R "$APP" /Applications/
    open /Applications/DriveSync.app
    echo "Installed to /Applications and launched."
fi

if [ "${1:-}" = dmg ]; then
    STAGE=build/dmg
    rm -rf "$STAGE" build/DriveSync.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname DriveSync -srcfolder "$STAGE" -ov -format UDZO build/DriveSync.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Built build/DriveSync.dmg"
fi
