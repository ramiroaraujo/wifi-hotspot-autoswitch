#!/bin/bash
# Build WifiAutoswitch.app via Xcode (project generated from project.yml by XcodeGen),
# then sign it with the local self-signed identity so the Location Services grant —
# keyed to the cert + bundle id — survives rebuilds.
#
# The version comes from the latest git tag, so cutting a release is just:
#   git tag v0.1.2 && ./build.sh
#
# Requires: Xcode, XcodeGen (brew install xcodegen). One-time: ./make-signing-cert.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "Generating Xcode project…"
xcodegen generate

echo "Building $VERSION (build $BUILD)…"
rm -rf build/dd build/WifiAutoswitch.app
xcodebuild -project WifiAutoswitch.xcodeproj -scheme WifiAutoswitch -configuration Release \
  -derivedDataPath build/dd \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO -quiet build
ditto "build/dd/Build/Products/Release/WifiAutoswitch.app" build/WifiAutoswitch.app

# Sign with the stable self-signed identity (preserves the Location grant); ad-hoc fallback.
CERT_NAME="WifiAutoswitch Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
  SIGN="$CERT_NAME"; echo "Signing with: $CERT_NAME"
else
  SIGN="-"; echo "Signing ad-hoc (run ./make-signing-cert.sh for a stable identity)"
fi
codesign --force --identifier com.ramiro.wifiautoswitch --sign "$SIGN" build/WifiAutoswitch.app
codesign --verify --verbose build/WifiAutoswitch.app 2>&1 | sed 's/^/  /'
echo "Built: $ROOT/build/WifiAutoswitch.app ($VERSION)"
