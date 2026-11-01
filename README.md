# MIDI Tools (Mantra)

**Two MIDI tools for the Mac in one menu-bar app, released on their own (31.10.2026):** MIDI TO MK CONTROL (a knob or key
of any MIDI controller becomes a Mackie Control command in Ableton Live: the playhead under a knob, PLAY / STOP from the
insert point, 121 commands) and MIDI TO KEY STROKE (a knob's CC or a key's note becomes a key stroke in the front app,
or the Mac's own volume).

Marko, 31.10.2026: *"make another application called MIDI Tools (Mantra) ... make it now independent. It's called MIDI to
MKEY Protocol, one application, and the other is MIDI to Keyboard."* ("MKEY" = MK Control, Mackie Control.)

- **Website:** https://mantramiditools.pages.dev (`site/public`, `tools/deploy_site.sh`): download with counter
  (`data-dl-app="miditools"`), install steps (Open Anyway; IAC Driver + Live's MackieControl surface; AbletonOSC
  optional), the donation bowl, visits, Speechify keys.
- **Build:** `./build.sh` (Apple Silicon + Intel, signed "Mantra Apps", installs to /Applications), `tools/make_dmg.sh`
  → `build/MantraMIDITools-<v>.dmg`. The version is the one number in `app/Common.swift`.
- **Code:** the MIDI to MK Control and MIDI to Key Stroke modules of ABLETON_LIVE_ACTIONS (v18), copied with
  Module.swift, Common.swift, Permissions.swift, Ports.swift and the umbrella (Main.swift) holding only these two.
  Settings in `~/.config/midi-tools.json` (Live Actions keeps `live-actions.json`). MIDI in the menu bar.
