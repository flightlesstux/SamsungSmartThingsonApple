#!/bin/zsh
# Builds the app and packages it as build/SmartPanel-<version>.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/SmartPanel.app/Contents/Info.plist)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R build/SmartPanel.app "$stage/"
ln -s /Applications "$stage/Applications"
dmg="build/SmartPanel-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "SmartPanel $version" -srcfolder "$stage" -format UDZO -ov "$dmg"
ls -lh "$dmg"
