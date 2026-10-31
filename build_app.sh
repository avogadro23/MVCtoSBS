#!/bin/bash
# Builds MVCtoSBS.app (needs Xcode command line tools: xcode-select --install)
set -e
cd "$(dirname "$0")"
swift build -c release
APP="MVCtoSBS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MVCtoSBS "$APP/Contents/MacOS/"
if [ -f Icon/AppIcon.icns ]; then cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

# Optional: bundle static ffmpeg/ffprobe builds if you put them next to this script
for t in ffmpeg ffprobe edge264mvc_test; do
  if [ -x "./$t" ]; then cp "./$t" "$APP/Contents/Resources/"; fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MVCtoSBS</string>
  <key>CFBundleDisplayName</key><string>MVCtoSBS</string>
  <key>CFBundleIdentifier</key><string>com.example.mvctosbs</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MVCtoSBS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep -s - "$APP"
echo "Built $APP — move it to /Applications."
