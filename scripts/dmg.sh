#!/usr/bin/env bash
# Pack build/neo-md.app into a drag-to-install DMG on the build Mac.
# Usage: scripts/dmg.sh   (run scripts/bundle.sh first)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd "$(dirname "$0")/.."

APP="build/neo-md.app"
STAGE="build/dmg"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
DMG="build/neo-md-${VERSION}.dmg"

[ -d "$APP" ] || { echo "missing $APP: run scripts/bundle.sh first" >&2; exit 1; }

trash "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/neo-md.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname neo-md -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "built $DMG"
