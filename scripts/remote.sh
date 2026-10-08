#!/usr/bin/env bash
# Sync the repo to the build Mac and run a command there.
# Usage: BUILD_HOST=<ssh host> scripts/remote.sh <build|test|bundle|dmg|run-cmd "<command>">
set -euo pipefail

BUILD_HOST="${BUILD_HOST:?set BUILD_HOST}"
REMOTE_DIR="${REMOTE_DIR:-neo-md}"

cd "$(dirname "$0")/.."

action="${1:-}"
case "$action" in
  build)   remote_cmd="swift build" ;;
  test)
    # Command Line Tools (no Xcode) ship Testing.framework outside the default
    # search paths, so pass them to the compiler, the linker and the rpath.
    fw="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
    # CLT also ships the _Testing_Foundation overlay binary without its
    # swiftmodule, so disable cross-import overlays or Foundation + Testing fails.
    remote_cmd="swift test -Xswiftc -F -Xswiftc $fw -Xlinker -F -Xlinker $fw -Xlinker -rpath -Xlinker $fw -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays"
    ;;
  bundle)  remote_cmd="scripts/bundle.sh" ;;
  dmg)     remote_cmd="scripts/dmg.sh" ;;
  run-cmd)
    remote_cmd="${2:?run-cmd needs a command}"
    ;;
  *)
    echo "usage: scripts/remote.sh <build|test|bundle|dmg|run-cmd \"<command>\">" >&2
    exit 2
    ;;
esac

rsync -az --delete \
  --exclude .build --exclude build --exclude .git \
  --exclude plans --exclude test-doc.md \
  ./ "$BUILD_HOST:$REMOTE_DIR/"

# ssh returns the remote exit code; set -e passes it through.
exec ssh "$BUILD_HOST" "cd $(printf '%q' "$REMOTE_DIR") && $remote_cmd"
