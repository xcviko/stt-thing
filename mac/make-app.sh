#!/bin/bash
# Builds stt-thing.app next to this script.
#
#   ./make-app.sh                  dev build: the app runs the backend from
#                                  ../backend of this repo (its .venv)
#   ./make-app.sh --release 0.1.0  release build: backend sources, a uv
#                                  binary and the speech model go inside the
#                                  app, in build/release/ with a zip for
#                                  GitHub Releases
#
# A release app installs Python and the backend packages with the bundled uv
# into ~/Library/Application Support/stt-thing/venv on first launch.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

RELEASE=0
VERSION="0.1.0"
if [[ "${1:-}" == "--release" ]]; then
  RELEASE=1
  VERSION="${2:?usage: ./make-app.sh --release <version>}"
fi

if [[ $RELEASE == 1 ]]; then
  APP="$PWD/build/release/stt-thing.app"
else
  APP="$PWD/build/stt-thing.app"
fi

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/stt-thing "$APP/Contents/MacOS/stt-thing"

BACKEND_KEY=""
if [[ $RELEASE == 1 ]]; then
  # Backend sources and the lock file, so uv installs exactly these versions.
  mkdir -p "$APP/Contents/Resources/backend" "$APP/Contents/Resources/bin"
  cp "$ROOT/backend/stt_server.py" "$ROOT/backend/agreement.py" \
     "$ROOT/backend/pyproject.toml" "$ROOT/backend/uv.lock" "$APP/Contents/Resources/backend/"
  # The speech model, so the app never needs Hugging Face (some networks
  # cannot download from it). Taken from the local HF cache, symlinks resolved.
  MODEL_ID="sonic-speech/parakeet-tdt-0.6b-v3-int8"
  MODEL_SRC="$("$ROOT/backend/.venv/bin/python" -c "from huggingface_hub import snapshot_download; print(snapshot_download('$MODEL_ID'))")"
  mkdir -p "$APP/Contents/Resources/model"
  for f in config.json model.safetensors tokenizer.model quantization_config.json README.md; do
    cp -L "$MODEL_SRC/$f" "$APP/Contents/Resources/model/$f"
  done
  # uv is a single binary that links only system libraries.
  UV_BIN="$(readlink -f "$(command -v uv)")"
  cp "$UV_BIN" "$APP/Contents/Resources/bin/uv"
  UV_HOME="$(dirname "$UV_BIN")/.."
  for f in LICENSE-MIT LICENSE-APACHE; do
    [[ -f "$UV_HOME/$f" ]] && cp "$UV_HOME/$f" "$APP/Contents/Resources/bin/uv-$f"
  done
else
  BACKEND_KEY="<key>STTBackendDir</key><string>$ROOT/backend</string>"
fi

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>stt-thing listens to the selected input (e.g. BlackHole) to show live captions.</string>
  $BACKEND_KEY
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"

if [[ $RELEASE == 1 ]]; then
  ZIP="$PWD/build/release/stt-thing-$VERSION-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zip:   $ZIP ($(du -h "$ZIP" | cut -f1))"
fi
