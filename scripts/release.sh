#!/bin/bash
# Builds a universal, Developer ID–signed and notarized Claudeman release,
# then publishes it to GitHub Releases.
#
# Usage: scripts/release.sh <version>        e.g. scripts/release.sh 0.2.0
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. Notary credentials stored in the keychain under the profile name below:
#      xcrun notarytool store-credentials claudeman-notary \
#          --apple-id <apple id email> --team-id <team id> --password <app-specific password>
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-claudeman-notary}"
OUT="build/release"
APP="build/Claudeman.app"
ZIP="$OUT/Claudeman-$VERSION.zip"
DMG="$OUT/Claudeman-$VERSION.dmg"

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: commit your changes before releasing." >&2
    exit 1
fi

echo "==> Building $TAG signed as: $SIGN_IDENTITY"
VERSION="$VERSION" UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" scripts/bundle.sh
codesign --verify --strict --verbose=2 "$APP"
lipo -archs "$APP/Contents/MacOS/Claudeman"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building disk image"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Claudeman $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)

echo "==> Publishing $TAG"
git tag -a "$TAG" -m "Claudeman $VERSION" 2>/dev/null || true
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" "$OUT/SHA256SUMS.txt" \
    --title "Claudeman $VERSION" \
    --notes-file "${NOTES_FILE:-scripts/release-notes.md}"
