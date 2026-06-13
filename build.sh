#!/bin/bash
# Build WifiAutoswitch.app — a minimal LSUIElement app bundle wrapping the Swift
# binary so it can hold Location Services permission (the cure for the redaction
# problem). Ad-hoc signed; that's enough for a local personal tool.
#
# NOTE: a rebuild changes the ad-hoc code signature (cdhash), which revokes the
# Location Services grant. You then re-enable "WifiAutoswitch" in
# System Settings → Privacy & Security → Location Services. Config lives in
# ~/Library/Application Support/wifi-hotspot-autoswitch/config.json so you rarely
# need to rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/WifiAutoswitch.app"
MACOS="$APP/Contents/MacOS"
EXE="$MACOS/wifi-autoswitch"
ID="com.ramiro.wifiautoswitch"

rm -rf "$APP"
mkdir -p "$MACOS"

echo "Compiling…"
swiftc -O -o "$EXE" "$ROOT/src/main.swift" \
  -framework CoreWLAN -framework CoreLocation -framework Foundation \
  -framework AppKit -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>wifi-autoswitch</string>
  <key>CFBundleIdentifier</key><string>${ID}</string>
  <key>CFBundleName</key><string>WifiAutoswitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>Read nearby Wi-Fi network names to switch between home Wi-Fi and the iPhone hotspot.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Read nearby Wi-Fi network names to switch between home Wi-Fi and the iPhone hotspot.</string>
  <key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>Read nearby Wi-Fi network names in the background to switch between home Wi-Fi and the iPhone hotspot.</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Prefer the stable self-signed identity (grant survives rebuilds); else ad-hoc.
CERT_NAME="WifiAutoswitch Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  SIGN="$CERT_NAME"
  echo "Signing with stable identity: $CERT_NAME"
else
  SIGN="-"
  echo "Signing ad-hoc (no stable identity found — Location grant will reset each rebuild)"
fi
codesign --force --identifier "$ID" --sign "$SIGN" "$EXE"
codesign --force --identifier "$ID" --sign "$SIGN" "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/  /' || true

echo "Built: $APP"
