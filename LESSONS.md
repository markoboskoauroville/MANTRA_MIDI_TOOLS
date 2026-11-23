# LESSONS: MIDI Tools (Mantra)

- 31.10.2026: a module family that only reaches through Module.swift / Common.swift lifts out into its own app with no
  code change (typecheck clean on the first try); the work is the names, the settings file and the menu-bar title.
- Defaults ON in a new app take the MIDI device away from a running app: on the author's Mac, write the settings file
  with modules OFF before the first launch.
- **The site screenshots were blank** (found 1.11.2026): shot-mk.png and shot-ks.png were one flat colour on the live page. Now `--shot <png> <tab> [w] [h]` draws the window off screen (no module started); check a picture with its pixel range before deploying.

- **A download link with the version in its name goes stale** (1.11.2026): the page linked MIDIToolsMantra-2.dmg and was right only because a session edited it by hand. Now the button links download/MIDITools.dmg, build.sh publishes every new version to that one address, and the version on the page is written from VERSION at deploy. Check the DMG on the bowl page is under 25 MB, else it needs a GitHub release.

## 13.11.2026

- 13.11.2026: audit a rewrite line by line against the old script before the old one is switched off.

## Lesson: hover card and pipes (16.11.2026)
Poll the mouse (macOS draws a status item once per display, only one copy owns the button, so a tracking area misses the other display). The panel needs `titleVisibility = .hidden` for the one-title guard. A non-activating NSPanel at statusBar+1 never takes focus. Pipes for text items: attributed title; for icon items: pipedIcon + rightPipe; for view items: drawPipes or PipesView.

## 22.11.2026 (v4): shared modules
Two copies of one module in two apps drift and both grab the same MIDI sources: one source (public repo MANTRA_MIDI_MODULES as a submodule, pinned,
hash-checked in both workflows), one on / off state, one owner lock (flock: the kernel frees it when the owner dies). Proven on the Mac: both apps
running, one owner; a switch pressed in the view app stopped the engine in the owner within a second; the owner quit and the other took over in a
second; the owner back as a view said "runs in ...". The website text must follow: "settings stay in midi-tools.json" was no longer true.

## 23.11.2026 (v5): AbletonOSC ports
AbletonOSC moved to UDP 11010/11011 (23.11.2026), Suno Bridge owns 11000. Shared MackieIO.swift and app/Ports.swift follow.
