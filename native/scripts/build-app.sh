#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo 'macOS SDK required' >&2; exit 1; }
VERSION=0.2.1
mkdir -p dist
APP="$PWD/dist/Pagekeep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  swift build -c release --arch "$ARCH" --product Pagekeep
  BIN=$(swift build -c release --arch "$ARCH" --show-bin-path)
  cp "$BIN/Pagekeep" "dist/Pagekeep-$ARCH"
done
lipo -create dist/Pagekeep-arm64 dist/Pagekeep-x86_64 -output "$APP/Contents/MacOS/Pagekeep"
cp Sources/Pagekeep/Resources/* "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pagekeep</string>
<key>CFBundleIdentifier</key><string>app.pagekeep.native</string>
<key>CFBundleName</key><string>Pagekeep</string>
<key>CFBundleDisplayName</key><string>Pagekeep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSCameraUsageDescription</key><string>由你允许的网站请求使用摄像头。</string>
<key>NSMicrophoneUsageDescription</key><string>由你允许的网站请求使用麦克风。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict></plist>
PLIST
chmod +x "$APP/Contents/MacOS/Pagekeep"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "dist/Pagekeep-$VERSION-macOS-universal.zip"
shasum -a 256 "dist/Pagekeep-$VERSION-macOS-universal.zip" > dist/SHA256SUMS.txt
lipo -info "$APP/Contents/MacOS/Pagekeep" | tee dist/architectures.txt
rm -f dist/Pagekeep-arm64 dist/Pagekeep-x86_64
