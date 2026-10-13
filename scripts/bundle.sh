#!/bin/bash
# Builds Claudeman in release mode and wraps it in a double-clickable .app bundle.
#
# Environment:
#   VERSION        marketing version (default 0.2.0)
#   UNIVERSAL=1    build for both Apple Silicon and Intel
#   SIGN_IDENTITY  codesign identity; "-" (default) is ad-hoc. A real identity also
#                  enables the hardened runtime and a secure timestamp, as notarization requires.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Claudeman.app"
VERSION="${VERSION:-0.2.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_FLAGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/Claudeman"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudeman"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claudeman</string>
    <key>CFBundleDisplayName</key><string>Claudeman</string>
    <key>CFBundleIdentifier</key><string>com.sausagerolls.claudeman</string>
    <key>CFBundleExecutable</key><string>Claudeman</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP"
