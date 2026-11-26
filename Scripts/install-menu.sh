#!/bin/bash
# Builds displayctl-menu and runs it as a LaunchAgent. Written for macOS /bin/bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LABEL="com.github.duncandoyle.displayctl-menu"
BIN_DIR="$HOME/.local/bin"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

echo "Building release binaries..."
swift build -c release --package-path "$REPO_ROOT"
BUILD_DIR="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"

# Install the CLI too, so both run the same build and share one ledger format.
mkdir -p "$BIN_DIR"
cp "$BUILD_DIR/displayctl-menu" "$BIN_DIR/displayctl-menu"
cp "$BUILD_DIR/displayctl" "$BIN_DIR/displayctl"
echo "Installed $BIN_DIR/displayctl-menu"
echo "Installed $BIN_DIR/displayctl (same build as the menu bar app)"

# Render the plist; '|' as delimiter since the path contains '/'.
mkdir -p "$AGENTS_DIR"
sed "s|__BINARY__|$BIN_DIR/displayctl-menu|" "$SCRIPT_DIR/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST"

# Stop an old instance; a missing one is fine.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  # bootout returns before the job is gone; bootstrap fails until it is.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done
fi
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "Loaded $LABEL:"
launchctl print "$DOMAIN/$LABEL" | grep -E '^[[:space:]]*(state|pid|last exit code) =' || true
