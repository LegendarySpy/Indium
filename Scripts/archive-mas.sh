#!/bin/zsh
# Archives the Mac App Store edition (scheme IndiumMAS, Release-AppStore) and exports it,
# signed for App Store Connect, to a local folder.
#   DEVELOPMENT_TEAM=ABCDE12345 Scripts/archive-mas.sh 1.1 [build]
#
# This script never uploads, notarizes or submits anything: there is no altool,
# notarytool or Transporter step, and the export's destination is a local folder
# ("export", not "upload"). Upload the result yourself, deliberately, when ready.
#
# Signing is automatic with your team, so Xcode needs to be signed in to an account in
# that team. The App Group id (TeamID.dev.garon.Indium) is derived from the team.
set -euo pipefail
cd "${0:A:h}/.."

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "error: DEVELOPMENT_TEAM isn't set. Run it as: DEVELOPMENT_TEAM=<your Team ID> Scripts/archive-mas.sh <version> [build]" >&2
  echo "       (Find your Team ID at developer.apple.com/account, under Membership details.)" >&2
  exit 1
fi
VERSION=${1:?version, e.g. 1.1}
BUILD=${2:-$(date +%Y%m%d%H%M)}
for part in "$VERSION" "$BUILD"; do
  if [[ ! "$part" =~ '^[0-9A-Za-z._-]+$' || "$part" == .* ]]; then
    echo "error: \"$part\" isn't a plain version or build number (letters, digits, . _ - only)." >&2
    exit 1
  fi
done
# Each version and build gets its own folder. Nothing here deletes or overwrites: an
# existing folder means that build was already archived, so the script stops.
OUT="build/AppStore/Indium-$VERSION-$BUILD"
ARCHIVE="$OUT/Indium.xcarchive"
if [[ -e "$OUT" ]]; then
  echo "error: $OUT already exists. Use a new build number, or move that folder away yourself." >&2
  exit 1
fi
mkdir -p "$OUT"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>export</string>
	<key>teamID</key>
	<string>$DEVELOPMENT_TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF

xcodegen generate -q
xcodebuild -project Indium.xcodeproj -scheme IndiumMAS -configuration Release-AppStore \
  -derivedDataPath build -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/Export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates

echo "Exported to $OUT/Export (not uploaded)."
