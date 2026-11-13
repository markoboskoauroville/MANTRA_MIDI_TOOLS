# LESSONS: MIDI Tools (Mantra)

- 31.10.2026: a module family that only reaches through Module.swift / Common.swift lifts out into its own app with no
  code change (typecheck clean on the first try); the work is the names, the settings file and the menu-bar title.
- Defaults ON in a new app take the MIDI device away from a running app: on the author's Mac, write the settings file
  with modules OFF before the first launch.
- **The site screenshots were blank** (found 1.11.2026): shot-mk.png and shot-ks.png were one flat colour on the live page. Now `--shot <png> <tab> [w] [h]` draws the window off screen (no module started); check a picture with its pixel range before deploying.

- **A download link with the version in its name goes stale** (1.11.2026): the page linked MIDIToolsMantra-2.dmg and was right only because a session edited it by hand. Now the button links download/MIDITools.dmg, build.sh publishes every new version to that one address, and the version on the page is written from VERSION at deploy. Check the DMG on the bowl page is under 25 MB, else it needs a GitHub release.

## 13.11.2026

- 13.11.2026: audit a rewrite line by line against the old script before the old one is switched off.
