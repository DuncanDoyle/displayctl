#!/bin/bash
# Stops displayctl-menu and removes its LaunchAgent. Written for macOS /bin/bash 3.2.
set -euo pipefail

LABEL="com.github.duncandoyle.displayctl-menu"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# Stop the running instance; a missing one is fine.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  echo "Stopped $LABEL"
else
  echo "$LABEL was not loaded"
fi

if [[ -f "$PLIST" ]]; then
  rm "$PLIST"
  echo "Removed $PLIST"
fi

echo "Kept $HOME/.local/bin/displayctl-menu and $HOME/.local/bin/displayctl"
echo "Kept the ledger in $HOME/Library/Application Support/displayctl/"
