#!/bin/bash
# Build lidless, install it to ~/.local/bin, and register it as a login agent.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin/lidless"
PLIST="$HOME/Library/LaunchAgents/com.local.lidless.plist"

mkdir -p "$HOME/.local/bin" "$HOME/.local/state"

echo "building..."
swiftc -O -o "$BIN" "$HERE/main.swift"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.lidless</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$HOME/.local/state/lidless.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "installed; running as pid $(pgrep -f "$BIN" || echo '?')"
