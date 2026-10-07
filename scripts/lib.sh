# Shared helpers for the build scripts. Source it; do not run it.

# Move old build output to /tmp/trash instead of deleting it.
trash() { if [ -e "$1" ]; then mkdir -p /tmp/trash && mv "$1" "/tmp/trash/$(basename "$1").$(date +%Y%m%d-%H%M%S)"; fi; }
