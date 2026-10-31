#!/bin/sh
# make_dmg.sh: the installer, a disk image with the app, a shortcut to Applications and the first-launch note
# (Marko, 31.10.2026: "please make a nice installation file. Then let people use it."). Run after build.sh.
set -e
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/Common.swift)
NAME="Mantra MIDI Tools"
STAGE=build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "build/$NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<TXT
Mantra MIDI Tools $V  —  https://mantramiditools.pages.dev

1. Drag "Mantra MIDI Tools" onto the Applications folder.
2. Open it. The first time, macOS says it cannot check the app, because it is signed by its author and not through
   Apple's paid program. Open System Settings > Privacy & Security, scroll down, and press "Open Anyway".
3. Allow Accessibility (System Settings > Privacy & Security > Accessibility): MIDI to Key Stroke presses keys in the
   app in front. The PERMISSIONS word at the top right of the window opens the right page.
4. MIDI in the menu bar opens the window. Two tools, each with ON / OFF:
   MIDI TO MK CONTROL: a knob or key of any MIDI controller becomes a Mackie Control command in Ableton Live
   (the playhead under a knob, PLAY / STOP, 121 commands). In Live, set a Control Surface to Mackie Control.
   MIDI TO KEY STROKE: a knob's CC or a key's note becomes a key stroke in the front app, or the Mac's own volume.

Free to use. If it helps you, put something in the bowl on the website.
TXT
cp "build/$NAME.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
OUT="build/MantraMIDITools-$V.dmg"; rm -f "$OUT" build/tmp.dmg
hdiutil create -quiet -volname "Mantra MIDI Tools $V" -srcfolder "$STAGE" -fs HFS+ -format UDRW build/tmp.dmg
D=$(hdiutil attach -nobrowse -noverify -noautoopen build/tmp.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')
command -v SetFile >/dev/null && SetFile -a C "$D" || true
hdiutil detach -quiet "$D"
hdiutil convert -quiet build/tmp.dmg -format UDZO -imagekey zlib-level=9 -o "$OUT"; rm -f build/tmp.dmg
codesign --force -s "Mantra Apps" "$OUT"
ls -l "$OUT"
