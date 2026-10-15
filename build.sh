#!/bin/zsh
# Builds SmartPanel.app (menu bar only) into ./build and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/SmartPanel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SmartPanel "$APP/Contents/MacOS/SmartPanel"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.flightlesstux.SmartPanel</string>
  <key>CFBundleName</key><string>SmartPanel</string>
  <key>CFBundleExecutable</key><string>SmartPanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>SmartPanel controls your Samsung TVs on the local network.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
