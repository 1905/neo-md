#!/usr/bin/env bash
# Make the update zip, sign it and write latest.json, on the build Mac.
# Usage: NEOMD_UPDATE_KEY=<key> scripts/release-feed.sh   (run scripts/bundle.sh first)
# BASE_URL overrides the download folder (default: the GitHub release of this version).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/neo-md.app"
[ -d "$APP" ] || { echo "missing $APP: run scripts/bundle.sh first" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_OS="$(plist LSMinimumSystemVersion)"
REPO="${GITHUB_REPOSITORY:-1905/neo-md}"
BASE_URL="${BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
ZIP="build/neo-md-${VERSION}.zip"

rm -f "$ZIP" build/latest.json
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
