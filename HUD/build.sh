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
  <key>NSLocalNetworkUsageDescription</key><string>voice-loop показывает плашку на вашем iPhone в домашней сети. Данные шифруются и не уходят в интернет.</string>
  <key>NSBonjourServices</key><array><string>_voiceloop._tcp</string></array>
  <key>NSMicrophoneUsageDescription</key><string>voice-loop слушает ваш ответ агенту, когда вы нажимаете на чат в плашке. Звук распознаётся локально и никуда не отправляется.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "built $PWD/$APP"
