#!/bin/zsh
# Builds Indium, signs and notarizes it, and writes a signed Sparkle appcast.
#   Scripts/release.sh 1.1 [build]
# CI runs this on every v* tag (see .github/workflows/release.yml).
#
# Signing uses a "Developer ID Application" certificate when one is in the keychain.
# Notarization uses APPLE_ID + APPLE_PASSWORD (CI) or the "Indium" notarytool
# keychain profile (local). Without them the build is ad hoc signed.
# Sparkle signs the update with SPARKLE_KEY_FILE (CI) or the login Keychain (local).
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:?version, e.g. 1.1}
BUILD=${2:-$(date +%Y%m%d%H%M)}
REPO="LegendarySpy/Indium"
TEAM="S8W699VPD7"
APP=build/Build/Products/Release/Indium.app
ZIP="Releases/Indium-$VERSION.zip"

IDENTITY=""
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  IDENTITY="Developer ID Application"
fi

xcodegen generate -q
xcodebuild -project Indium.xcodeproj -scheme Indium -configuration Release -derivedDataPath build -quiet \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build

if [[ -n "$IDENTITY" ]]; then
  # Inside out: Sparkle's helpers, the framework, the Quick Look extension, then the app.
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
  S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$S/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
  sign "$S/Autoupdate" "$S/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign --entitlements QuickLook/QuickLook.entitlements "$APP/Contents/PlugIns/IndiumQuickLook.appex"
  sign "$APP"
  codesign --verify --deep --strict "$APP"
fi

rm -rf Releases && mkdir Releases
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

NOTARY=()
if [[ -n "${APPLE_PASSWORD:-}" ]]; then
  NOTARY=(--apple-id "${APPLE_ID:?}" --password "$APPLE_PASSWORD" --team-id "$TEAM")
elif xcrun notarytool history --keychain-profile Indium >/dev/null 2>&1; then
  NOTARY=(--keychain-profile Indium)
fi
if [[ -n "$IDENTITY" && ${#NOTARY} -gt 0 ]]; then
  xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
else
  echo "Not notarizing (no Developer ID certificate or notary credentials)."
fi

SIGN=(--account indium)
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && SIGN=(--ed-key-file "$SPARKLE_KEY_FILE")
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast "${SIGN[@]}" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" Releases

echo "Built $ZIP and Releases/appcast.xml"
