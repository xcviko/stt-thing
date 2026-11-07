#!/bin/bash
# Builds "STT Thing.app" next to this script. The app runs the Python backend
# from ../backend of this repo, so keep the repo where it is.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$PWD/build/STT Thing.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/STTThing "$APP/Contents/MacOS/STTThing"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>STT Thing</string>
  <key>CFBundleDisplayName</key><string>STT Thing</string>
  <key>CFBundleIdentifier</key><string>com.xcviko.stt-thing</string>
  <key>CFBundleExecutable</key><string>STTThing</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>STT Thing listens to the selected input (e.g. BlackHole) to show live captions.</string>
  <key>STTBackendDir</key><string>$ROOT/backend</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
