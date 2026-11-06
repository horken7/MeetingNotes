#!/bin/bash
# Prints the app's Info.plist. Shared by install.sh (source build) and packaging/build-app.sh (DMG).
#   bash packaging/info-plist.sh [version] [build number]
set -euo pipefail
VERSION="${1:-1.0}"
BUILD_NUMBER="${2:-1}"
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>se.frinkle.meetingnotes</string>
  <key>CFBundleName</key><string>Meeting Notes</string>
  <key>CFBundleDisplayName</key><string>Meeting Notes</string>
  <key>CFBundleExecutable</key><string>MeetingNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Meeting Notes reads the call tab's title in your browser to name the meeting.</string>
  <key>NSMicrophoneUsageDescription</key><string>Meeting Notes records your side of the call to transcribe it.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Meeting Notes records the other people on the call (the sound your Mac plays) to transcribe it.</string>
</dict>
</plist>
PLIST
