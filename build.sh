#!/bin/zsh
# สร้าง Agent Grove.app จาก main.swift (SwiftUI + Core Animation) + Sprites/  (ต้องมี Xcode Command Line Tools)
set -e
cd "${0:A:h}"
APP="build/Agent Grove.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library main.swift -o "$APP/Contents/MacOS/AgentGrove"
cp -R Sprites "$APP/Contents/Resources/Sprites"

# ไอคอนแอป: วาด 🐾 ลงพื้นสีเขียวด้วย Swift แล้วแปลงเป็น .icns
swift icon.swift build/icon.png
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Agent Grove</string>
  <key>CFBundleDisplayName</key><string>Agent Grove</string>
  <key>CFBundleIdentifier</key><string>local.agentgrove</string>
  <key>CFBundleExecutable</key><string>AgentGrove</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"
echo "สร้างเสร็จ: $PWD/$APP"
