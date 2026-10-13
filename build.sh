#!/bin/bash
# Builds "Lecture Notes.app" into ./dist (run on a Mac with the Xcode command line tools).
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Lecture Notes.app"
rm -rf dist build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

swiftc -O -parse-as-library -target arm64-apple-macos14.0 app/main.swift -o "$APP/Contents/MacOS/LectureNotes"

swiftc -O app/make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lecture Notes</string>
  <key>CFBundleDisplayName</key><string>Lecture Notes</string>
  <key>CFBundleIdentifier</key><string>com.ozairkhan.lecturenotes</string>
  <key>CFBundleExecutable</key><string>LectureNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "built $APP"
