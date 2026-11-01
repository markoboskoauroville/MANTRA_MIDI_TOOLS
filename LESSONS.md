# LESSONS: MIDI Tools (Mantra)

- 31.10.2026: a module family that only reaches through Module.swift / Common.swift lifts out into its own app with no
  code change (typecheck clean on the first try); the work is the names, the settings file and the menu-bar title.
- Defaults ON in a new app take the MIDI device away from a running app: on the author's Mac, write the settings file
  with modules OFF before the first launch.
- **The site screenshots were blank** (found 1.11.2026): shot-mk.png and shot-ks.png were one flat colour on the live page. Now `--shot <png> <tab> [w] [h]` draws the window off screen (no module started); check a picture with its pixel range before deploying.
