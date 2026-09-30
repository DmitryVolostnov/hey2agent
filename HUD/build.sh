#!/bin/zsh
# Builds VoiceLoopHUD.app (menu-bar only, no Dock icon) next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=VoiceLoopHUD.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp .build/release/VoiceLoopHUD $APP/Contents/MacOS/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>me.volostnov.voiceloop.hud</string>
  <key>CFBundleName</key><string>VoiceLoopHUD</string>
  <key>CFBundleExecutable</key><string>VoiceLoopHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "built $PWD/$APP"
