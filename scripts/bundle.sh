#!/usr/bin/env bash
# Build neo-md.app on the build Mac. Run from anywhere; works from the repo root.
# Usage: scripts/bundle.sh          (NO_QL=1 skips the Quick Look extension)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd "$(dirname "$0")/.."

NO_QL="${NO_QL:-0}"
BIN_DIR=".build/arm64-apple-macosx/release"
APP="build/neo-md.app"
ICONSET="build/AppIcon.iconset"

# 1. Build.
swift build -c release --arch arm64

# 2. App skeleton, binary and Info.plist.
trash "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/neo-md" "$APP/Contents/MacOS/neo-md"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# 3. Quick Look extension (.appex). NO_QL=1 skips it.
APPEX="$APP/Contents/PlugIns/NeoMDQuickLook.appex"
if [ "$NO_QL" != "1" ]; then
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$BIN_DIR/NeoMDQuickLook" "$APPEX/Contents/MacOS/NeoMDQuickLook"
  cp Resources/QuickLook-Info.plist "$APPEX/Contents/Info.plist"
fi

# 4. App icon: 16 and 32 px slots from the small PNG, 128 px and up from the 1024 PNG.
trash "$ICONSET"
mkdir -p "$ICONSET"
small="Resources/AppIcon-small-64.png"
large="Resources/AppIcon-1024.png"
for src in "$small" "$large"; do
  [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
done
icon() { # icon <source png> <pixels> <slot name>
  sips -z "$2" "$2" "$1" --out "$ICONSET/$3.png" >/dev/null
}
icon "$small" 16   icon_16x16
icon "$small" 32   icon_16x16@2x
icon "$small" 32   icon_32x32
icon "$small" 64   icon_32x32@2x
icon "$large" 128  icon_128x128
icon "$large" 256  icon_128x128@2x
icon "$large" 256  icon_256x256
icon "$large" 512  icon_256x256@2x
icon "$large" 512  icon_512x512
icon "$large" 1024 icon_512x512@2x
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 5. Sign nested code first (the .appex with its sandbox entitlements), then the app.
#    No --deep: it would re-sign the .appex without its entitlements.
if [ "$NO_QL" != "1" ]; then
  codesign --force --sign - --entitlements Resources/QuickLook.entitlements "$APPEX"
fi
codesign --force --sign - "$APP"

echo "built $APP"
