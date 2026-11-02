#!/usr/bin/env bash
# Builds Nits.app without Xcode: swift build, then assemble the bundle by hand.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Nits"
BUNDLE_ID="app.nits.macos"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product Nits
swift build -c "$CONFIG" --product nitsctl

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Nits" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/nitsctl" "$APP/Contents/MacOS/nitsctl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Nits — free and open source</string>
    <key>NSAppleEventsUsageDescription</key><string>Nits uses System Events to toggle Dark Mode when you ask it to.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>nits</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "warning: codesign failed; the app may still run locally" >&2
}

echo "Built $APP"
echo "Run: open \"$APP\""
echo "CLI: \"$APP/Contents/MacOS/nitsctl\" list"
