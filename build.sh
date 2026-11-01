#!/bin/sh
# build.sh: MIDI Tools (Mantra).app (MIDI to MK Control + MIDI to Key Stroke, out of Ableton Live Actions, 31.10.2026),
# swiftc straight, no Xcode, Apple Silicon + Intel, signed "Mantra Apps". The version is the one number in app/Common.swift.
set -e
cd "$(dirname "$0")"
# ./build.sh               build, install, then publish: DMG + page (download-always-latest.md, 1.11.2026)
# ./build.sh --no-publish  build and install only
PUBLISH=1; for a in "$@"; do case "$a" in --no-publish) PUBLISH=0;; esac; done
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/Common.swift)
NAME="MIDI Tools (Mantra)"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -o build/MidiTools-arm64 app/*.swift
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos14.0 -o build/MidiTools-x86_64 app/*.swift
lipo -create build/MidiTools-arm64 build/MidiTools-x86_64 -output "$APP/Contents/MacOS/MantraMidiTools"
(cd icon && swift make_icon.swift "$V" >/dev/null)
I=build/AppIcon.iconset; rm -rf $I; mkdir -p $I
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon_1024.png --out $I/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon_1024.png --out $I/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $I -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>community.auroville.miditools</string>
<key>CFBundleExecutable</key><string>MantraMidiTools</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
rm -rf "$APP/Contents/Resources/helpers"; cp -R helpers "$APP/Contents/Resources/helpers"
codesign --force -s "Mantra Apps" "$APP"
rm -rf "/Applications/$NAME.app"; cp -R "$APP" /Applications/
echo "built $APP (v$V) and installed it in /Applications"
# the release step: every new version reaches the page in the same run (MANTRA_MANIFEST download-always-latest.md)
if [ "$PUBLISH" = 1 ]; then
  tools/make_dmg.sh
  tools/deploy_site.sh
else
  echo "not published (--no-publish)"
fi
