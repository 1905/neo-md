#!/usr/bin/env bash
# Make the update zip, sign it and write latest.json, on the build Mac.
# Usage: NEOMD_UPDATE_KEY=<key> scripts/release-feed.sh   (run scripts/bundle.sh first)
# BASE_URL overrides the download folder (default: the GitHub release of this version).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

cd "$(dirname "$0")/.."

APP="build/neo-md.app"
[ -d "$APP" ] || { echo "missing $APP: run scripts/bundle.sh first" >&2; exit 1; }

INFO="$APP/Contents/Info.plist"
VERSION="$(plist "$INFO" CFBundleShortVersionString)"
BUILD="$(plist "$INFO" CFBundleVersion)"
MIN_OS="$(plist "$INFO" LSMinimumSystemVersion)"
REPO="${GITHUB_REPOSITORY:-1905/neo-md}"
BASE_URL="${BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
ZIP="build/neo-md-${VERSION}.zip"

trash "$ZIP"
trash build/latest.json
ditto -c -k --keepParent "$APP" "$ZIP"
SIZE="$(stat -f %z "$ZIP")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIG="$(swift scripts/sign-update.swift "$ZIP")"

cat > build/latest.json <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "url": "$BASE_URL/neo-md-$VERSION.zip",
  "size": $SIZE,
  "sha256": "$SHA",
  "signature": "$SIG",
  "minimumSystemVersion": "$MIN_OS"
}
JSON

echo "built $ZIP and build/latest.json"
