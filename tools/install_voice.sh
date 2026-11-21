#!/bin/bash
# Install (or update) the Desk Buddy voice worker as a macOS LaunchAgent.
#   com.deskbuddy.voice   local mlx-whisper STT -> Antigravity SDK -> TTS (:47824)
# Uninstall: tools/install_voice.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="$HOME/.desk-buddy"
LABEL="com.deskbuddy.voice"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  echo "Voice worker removed."
  exit 0
fi

mkdir -p "$RT" "$HOME/Library/LaunchAgents"
cp "$ROOT/tools/voice_worker.py" "$RT/voice_worker.py"
cp "$ROOT/tools/dashboard.html" "$RT/dashboard.html"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$RT/venv/bin/python</string><string>-u</string><string>$RT/voice_worker.py</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$RT/voice.out</string>
  <key>StandardErrorPath</key><string>$RT/voice.out</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 2
curl -s -m 2 http://127.0.0.1:47824/health && echo
echo "Desk Buddy voice worker running on :47824."
