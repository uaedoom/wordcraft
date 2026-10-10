#!/bin/zsh
# Builds, archives and exports WordCraft for the Mac App Store.
# Usage: scripts/archive-appstore.sh <TEAM_ID>
set -euo pipefail
TEAM="${1:?Pass your Apple Developer Team ID, e.g. ABCDE12345}"
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project WordMac.xcodeproj -scheme WordMac -configuration AppStore \
  -archivePath build/WordCraft.xcarchive DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates archive
sed "s/TEAM_ID_HERE/$TEAM/" ExportOptions.plist > build/ExportOptions.resolved.plist
xcodebuild -exportArchive -archivePath build/WordCraft.xcarchive \
  -exportOptionsPlist build/ExportOptions.resolved.plist -exportPath build/export -allowProvisioningUpdates
echo "Done. Upload build/export/*.pkg with Transporter, or: xcrun altool --upload-app -f build/export/WordCraft.pkg -t macos"
