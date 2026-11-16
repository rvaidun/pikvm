#!/bin/bash
# Build MacForward Preview.app (menubar preview of what forward.sh sends).
#   ./build.sh            build into build/
#   ./build.sh --install  also copy it to ~/Applications and launch it
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/MacForward Preview.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -framework AppKit -o "$APP/Contents/MacOS/MacForwardPreview" "$HERE/main.swift"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.rahkvm.macforward-preview</string>
  <key>CFBundleName</key><string>MacForward Preview</string>
  <key>CFBundleExecutable</key><string>MacForwardPreview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p ~/Applications
  pkill -x MacForwardPreview 2>/dev/null || true
  rm -rf ~/Applications/"MacForward Preview.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"MacForward Preview.app"
  echo "Installed to ~/Applications and launched"
fi
