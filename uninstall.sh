#!/bin/bash
# Remove the login agent, the binary, and the saved state.
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.local.lidless.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/lidless" \
      "$HOME/.local/state/lidless-brightness" "$HOME/.local/state/lidless.log"
echo "uninstalled (source in this folder is untouched)"
