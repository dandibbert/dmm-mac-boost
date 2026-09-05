#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p .build/arm64 .build/x86_64 out
for ARCH in arm64 x86_64; do
  xcrun clang -fobjc-arc -O2 -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min=14.0 \
    -c Sources/Bridge.m -o ".build/$ARCH/Bridge.o"
  xcrun swiftc -parse-as-library -swift-version 5 -O -g \
    -target "$ARCH-apple-macos14.0" -sdk "$SDK" \
    -import-objc-header Sources/Bridge.h Sources/*.swift ".build/$ARCH/Bridge.o" \
    -framework Cocoa -framework WebKit -o ".build/$ARCH/Still"
done
APP="out/Still.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun lipo -create .build/arm64/Still .build/x86_64/Still -output "$APP/Contents/MacOS/Still"
xcrun lipo "$APP/Contents/MacOS/Still" -verify_arch arm64 x86_64
cp Resources/* "$APP/Contents/Resources/"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Still</string>
<key>CFBundleDisplayName</key><string>Still</string>
<key>CFBundleIdentifier</key><string>app.still.browser</string>
<key>CFBundleExecutable</key><string>Still</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>CFBundleIconFile</key><string>Still.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSCameraUsageDescription</key><string>只有在你明确允许网站访问时，Still 才会请求使用摄像头。</string>
<key>NSMicrophoneUsageDescription</key><string>只有在你明确允许网站访问时，Still 才会请求使用麦克风。</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
</dict></plist>
PLIST
xcrun swift scripts/Icon.swift .build/Still.iconset
xcrun iconutil -c icns .build/Still.iconset -o "$APP/Contents/Resources/Still.icns"
chmod +x "$APP/Contents/MacOS/Still"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$APP" out/Still-macOS-universal.zip
shasum -a 256 out/Still-macOS-universal.zip > out/SHA256SUMS.txt
