#!/bin/bash
# Builds titi and packs it as dist/Titi.app (ad-hoc signed). Install: drag dist/Titi.app to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release 2>&1 | grep -E "error|warning: unre|Build" || true
APP=dist/Titi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Titi "$APP/Contents/MacOS/Titi"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>titi</string>
    <key>CFBundleDisplayName</key><string>titi</string>
    <key>CFBundleIdentifier</key><string>com.alexsisu.titi</string>
    <key>CFBundleExecutable</key><string>Titi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>titi reads your iTerm tabs to find Claude and Codex sessions, and brings a tab forward when you ask.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "packed $APP ($VERSION)"
