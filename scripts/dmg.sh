#!/usr/bin/env bash
# Pack build/neo-md.app into a drag-to-install DMG on the build Mac.
# Usage: scripts/dmg.sh   (run scripts/bundle.sh first)
set -euo pipefail

# Move old build output to /tmp/trash instead of deleting it.
trash() { if [ -e "$1" ]; then mkdir -p /tmp/trash && mv "$1" "/tmp/trash/$(basename "$1").$(date +%Y%m%d-%H%M%S)"; fi; }

cd "$(dirname "$0")/.."

APP="build/neo-md.app"
STAGE="build/dmg"
DMG="build/neo-md-0.1.0.dmg"

[ -d "$APP" ] || { echo "missing $APP: run scripts/bundle.sh first" >&2; exit 1; }

trash "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/neo-md.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname neo-md -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "built $DMG"
