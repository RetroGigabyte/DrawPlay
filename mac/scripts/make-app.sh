#!/bin/bash
# Builds DrawPlay.app (release) into mac/build/. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product DrawPlay 2>&1 | grep -E "error|Compiling|Build complete" | tail -3

APP=build/DrawPlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DrawPlay "$APP/Contents/MacOS/DrawPlay"

# SwiftPM stamps the binary as built with the macOS 13 SDK (its deployment target). macOS only gives an app the Liquid Glass
# look when it was built with the current SDK, so stamp the real SDK version (the minimum macOS stays 13).
SDKVER=$(xcrun --show-sdk-version 2>/dev/null || echo 27.0)
vtool -set-build-version macos 13.0 "$SDKVER" -replace -output "$APP/Contents/MacOS/DrawPlay" "$APP/Contents/MacOS/DrawPlay" 2>&1 | grep -v "^$" || true

# App icon: built from the full-bleed artwork in ../DrawPlay Icons (opaque square, so macOS applies its own mask and the
# picture fills the whole tile). Rebuilt whenever the PNG is newer than mac/AppIcon.icns.
ICON_SRC="../DrawPlay Icons/DrawPlay-FullBleed-1024.png"
if [ -f "$ICON_SRC" ] && { [ ! -f AppIcon.icns ] || [ "$ICON_SRC" -nt AppIcon.icns ]; }; then
    IS=$(mktemp -d)/AppIcon.iconset; mkdir -p "$IS"
    for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
        sips -z "${spec%%:*}" "${spec%%:*}" "$ICON_SRC" --out "$IS/${spec##*:}.png" >/dev/null
    done
    iconutil -c icns "$IS" -o AppIcon.icns && echo "rebuilt AppIcon.icns from the full-bleed artwork"
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Bundle the tablet app so "Install app on tablet" works with one click.
APK=../DrawPlay.apk
[ -f "$APK" ] && cp "$APK" "$APP/Contents/Resources/DrawPlay.apk" && echo "bundled $APK" || echo "note: no ../DrawPlay.apk to bundle"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DrawPlay</string>
  <key>CFBundleDisplayName</key><string>DrawPlay</string>
  <key>CFBundleIdentifier</key><string>dev.drawplay.host</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>DrawPlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Ad-hoc signature with a requirement based on the bundle id instead of the build's hash.
# macOS remembers permissions (Accessibility, Screen Recording) by this requirement, so they
# survive rebuilds. Without it every rebuild looks like a new app and the old grant stops working.
codesign --force --deep --sign - -r='designated => identifier "dev.drawplay.host"' "$APP" 2>&1 | tail -1
echo "built $APP"

# Optional: ./scripts/make-app.sh --install  copies the app into /Applications.
if [ "${1:-}" = "--install" ]; then
    pkill -f "DrawPlay.app/Contents/MacOS/DrawPlay" 2>/dev/null || true
    rm -rf /Applications/DrawPlay.app && ditto "$APP" /Applications/DrawPlay.app && echo "installed /Applications/DrawPlay.app"
fi
