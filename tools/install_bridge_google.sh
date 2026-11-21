#!/bin/bash
# Install (or update) the Desk Buddy bridge for Antigravity / Google coding (without the Claude desktop app watcher).
#   com.deskbuddy.bridge    Python bridge: Antigravity hooks -> Lump (Mac Lump.app and/or ESP32 prism)
# Uninstall: tools/install_bridge_google.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$HOME/.desk-buddy"
LABEL="com.deskbuddy.bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  echo "Bridge removed (runtime left in $RT)."
  exit 0
fi

mkdir -p "$RT" "$HOME/Library/LaunchAgents"
[ -x "$RT/venv/bin/python" ] || python3 -m venv "$RT/venv"
"$RT/venv/bin/pip" -q install --disable-pip-version-check --upgrade pip
"$RT/venv/bin/pip" -q install --disable-pip-version-check pyserial icalendar recurring-ical-events
cp "$ROOT/tools/buddy_bridge.py" "$RT/bridge.py"
cp "$ROOT/design/lump.html" "$RT/lump.html"

# Lump's ocarina voice and gag sound effects
python3 "$ROOT/tools/make_sounds.py"
python3 "$ROOT/tools/make_gag_sounds.py"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$RT/venv/bin/python</string><string>-u</string><string>$RT/bridge.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$RT/bridge.out</string>
  <key>StandardErrorPath</key><string>$RT/bridge.out</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 2
curl -s -m 2 http://127.0.0.1:47823/status && echo
echo "Desk Buddy bridge running (without Claude appwatch)."
