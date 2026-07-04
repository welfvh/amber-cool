#!/bin/bash
# Build "Amber Cool.app" (menu bar / LSUIElement) and sign it.
# Uses Developer ID if available (release), else ad-hoc (local testing).
#   ./app/bundle.sh [--notarize]
# --notarize: submit to Apple notary service and staple (requires keychain profile "notarytool").
set -euo pipefail

NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

echo "==> Building release"
swift build -c release --product AmberCoolApp >/dev/null

APP="build/Amber Cool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/AmberCoolApp" "$APP/Contents/MacOS/amber-cool"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Amber Cool</string>
    <key>CFBundleDisplayName</key><string>Amber Cool</string>
    <key>CFBundleIdentifier</key><string>co.welf.amber-cool</string>
    <key>CFBundleExecutable</key><string>amber-cool</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing: prefer Developer ID for release; fall back to ad-hoc for local runs.
DEVID="Developer ID Application: Potential, Inc. (6Y24LA63S7)"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$DEVID"; then
    echo "==> Signing with Developer ID (hardened runtime)"
    codesign --force --options runtime --timestamp \
        --sign "$DEVID" "$APP" >/dev/null
else
    echo "==> Developer ID not found — ad-hoc signing (local testing only)"
    codesign --force --sign - "$APP" >/dev/null
fi

if [[ $NOTARIZE -eq 1 ]]; then
    echo "==> Notarizing (takes a few minutes)"
    ZIP="build/AmberCool-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "notarytool" --wait --timeout 20m
    rm -f "$ZIP"
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    spctl --assess --type execute -v "$APP" || true
fi

codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -3 || true
echo "==> Built $APP"
