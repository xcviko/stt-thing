#!/bin/bash
# Builds "stt-thing.app" next to this script. The app runs the Python backend
# from ../backend of this repo, so keep the repo where it is.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$PWD/build/stt-thing.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/stt-thing "$APP/Contents/MacOS/stt-thing"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>stt-thing</string>
  <key>CFBundleDisplayName</key><string>stt-thing</string>
  <key>CFBundleIdentifier</key><string>com.xcviko.stt-thing</string>
  <key>CFBundleExecutable</key><string>stt-thing</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>stt-thing listens to the selected input (e.g. BlackHole) to show live captions.</string>
  <key>STTBackendDir</key><string>$ROOT/backend</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
