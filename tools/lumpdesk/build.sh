#!/bin/zsh
# Build "LumpDesk" (floating virtual prism desktop companion with voice) into ~/Applications/LumpDesk.app and launch it.
set -euo pipefail
HERE="${0:A:h}"
ROOT="$(cd "$HERE/../.." && pwd)"
APP="$HOME/Applications/LumpDesk.app"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -O -swift-version 5 "$HERE/main.swift" "$HERE/MeetingRecorder.swift" -framework Cocoa -framework WebKit -framework AVFoundation -framework CoreAudio -framework Carbon -framework ScreenCaptureKit -framework CoreMedia -o "$BUILD/LumpDesk"

pkill -x LumpDesk 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/LumpDesk" "$APP/Contents/MacOS/LumpDesk"

if [ -f "$ROOT/tools/lumpbar/frames/awake-glow-k.png" ] && [ -f "$ROOT/tools/lumpbar/frames/awake-glow-w.png" ]; then
  cp "$ROOT/tools/lumpbar/frames/awake-glow-k.png" "$APP/Contents/Resources/awake-glow-k.png"
  cp "$ROOT/tools/lumpbar/frames/awake-glow-w.png" "$APP/Contents/Resources/awake-glow-w.png"
fi
if [ -f "$ROOT/tools/lumpbar/icon.png" ]; then
  cp "$ROOT/tools/lumpbar/icon.png" "$APP/Contents/Resources/menuicon.png"
  ICONSET="$BUILD/LumpDesk.iconset"; mkdir -p "$ICONSET"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$ROOT/tools/lumpbar/icon.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$ROOT/tools/lumpbar/icon.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/LumpDesk.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.deskbuddy.lumpdesk</string>
  <key>CFBundleName</key><string>LumpDesk</string>
  <key>CFBundleExecutable</key><string>LumpDesk</string>
  <key>CFBundleIconFile</key><string>LumpDesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>LumpDesk listens to your voice when you click the mic button so you can assign tasks to Lump.</string>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
open "$APP"
echo "LumpDesk (with voice) is running from $APP"
