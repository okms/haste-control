#!/bin/zsh
# Builds dist/Haste Control.app (menu-bar app) and dist/hastectl.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail
cd "${0:A:h}/.."
APP="dist/Haste Control.app"

swift build -c release --product HasteBar
swift build -c release --product hastectl
BIN="$(swift build -c release --show-bin-path)"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/HasteBar" "$APP/Contents/MacOS/HasteBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/hastectl" dist/hastectl
codesign --force --deep --sign - "$APP"
codesign --force --sign - dist/hastectl
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x HasteBar 2>/dev/null || true
  rm -rf "/Applications/Haste Control.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Haste Control.app"
  open "/Applications/Haste Control.app"
fi
