#!/bin/bash
# Builds Zquig.app (Apple Silicon, arm64) into ./dist
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Zquig
APP=dist/Zquig.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Zquig"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Zquig</string>
<key>CFBundleDisplayName</key><string>Zquig</string>
<key>CFBundleIdentifier</key><string>local.zquig.app</string>
<key>CFBundleExecutable</key><string>Zquig</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Image or PDF</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSItemContentTypes</key><array><string>public.image</string><string>com.adobe.pdf</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"; lipo -archs "$APP/Contents/MacOS/Zquig"
