#!/bin/bash
# What must not change by accident: the display name, the bundle id, the executable, the page, the shared sources.
cd "$(dirname "$0")/.." || exit 1
fail=0
need() { grep -q -F -- "$2" "$1" || { echo "FAIL $1 lacks: $2"; fail=1; }; }
need build.sh 'NAME="MIDI Tools (Mantra)"'
need build.sh '<key>CFBundleIdentifier</key><string>community.auroville.miditools</string>'
need build.sh '<key>CFBundleExecutable</key><string>MantraMidiTools</string>'
need build.sh 'shared/*.swift'
need app/Common.swift 'let APP_NAME = "MIDI Tools (Mantra)"'
need app/Common.swift 'let RELEASES = "https://mantramiditools.pages.dev"'
need app/Common.swift 'func enforceOneTitle()'
need app/Updater.swift 'static let repo = "markoboskoauroville/MANTRA_MIDI_TOOLS"'
need .gitmodules 'MANTRA_MIDI_MODULES'
need shared.sha256 ''
grep -q 'id: "off"' app/Main.swift && { echo "FAIL the app-level OFF is back"; fail=1; }
[ "$(grep -c 'Text("v\\(VERSION)")' app/Main.swift)" = 1 ] || { echo "FAIL the version is not drawn exactly once"; fail=1; }
[ $fail = 0 ] && echo "pins: OK"
exit $fail
