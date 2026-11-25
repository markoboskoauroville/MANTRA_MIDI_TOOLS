# TAKEOVER: MIDI Tools (Mantra)

- 31.10.2026: v1 made from ABLETON_LIVE_ACTIONS v18 (the two MIDI modules), renamed (window, MIDI client names,
  permissions text), its own settings file, menu-bar title MIDI, version link to the website. Typecheck clean, built
  universal, installed, opened with both modules OFF in ~/.config/midi-tools.json on Marko's Mac (so it does not take the
  E16 from Live Actions, whose modules are still in it), two window captures, quit. DMG 1.46 MB. Site deployed and
  checked live (page, DMG, bowl, picture 200).
- Not done: the modules ON on another Mac (no second Mac here); Live Actions still carries the same two modules: run one
  or the other on a controller, never both.


## Publishing: the download button always gives the newest version (1.11.2026)

MANTRA_MANIFEST modules/download-always-latest.md. The button on https://miditools.markobosko.org links one address that never
changes: **https://miditools.markobosko.org/download/MIDITools.dmg**. Nobody edits the page for a new version.

- `./build.sh` builds, signs, installs, then publishes by itself: `tools/make_dmg.sh` (build/MIDIToolsMantra-<V>.dmg) and
  `tools/deploy_site.sh`. `./build.sh --no-publish` builds and installs only.
- `tools/deploy_site.sh` takes V from `let VERSION` in app/Common.swift, refuses a DMG of 25 MB or more (Cloudflare Pages' limit:
  then a GitHub release, per the module), removes every .dmg from site/public, copies the DMG to
  site/public/download/MIDITools.dmg, adds the `site/public/_redirects` line(s) that send the old versioned names
  (`/MIDIToolsMantra-*`) to it with a 301, writes the version and the size into `<span id="app-version">` and
  `<span id="app-size">` of index.html, runs the SEO kit with `--download download/MIDITools.dmg`, checks no versioned
  name is left on the page, and deploys with wrangler. To publish the current version again without building:
  `tools/deploy_site.sh` (the DMG in build/ must exist).
- The check after a release: `curl -sI https://miditools.markobosko.org/download/MIDITools.dmg` answers 200 and the page shows
  the new version.
- 1.11.2026: v2 put behind the fixed address, live checked: 200, the same bytes as build/MIDIToolsMantra-2.dmg (1475952), MIDIToolsMantra-2.dmg and MantraMIDITools-1.dmg → 301, the page says Version 2.

## State at close, 13.11.2026

13.11.2026: audited against the Lua it replaces; first GitHub build of v2 (public repo); it now holds the MK Control (Mackie) and key-stroke engines the star used to load.

## Menu-bar hover card and pipes (v3, 16.11.2026)
Marko: "with all my apps on the menu bar, make a comprehensive pop-up menu. When I hover over, I want to see what is it and what is it doing." and "for my apps always make a pipes before and after so I know where one app ends and other begins." `app/HoverCard.swift` is the shared kit file (MANTRA_MANIFEST kits/menubar-hover, rule modules/menubar-hover.md): hovering the item about 0.4 s shows a card with name, what it is, state and live lines; a thin grey pipe stands before and after the visible title. The app supplies its lines in the `HoverCard.attach(...)` closure. Test without a mouse: launch with `--hovercard-shot`. Change the lines in the app; change the module only in the kit.

## v4, 22.11.2026: the MIDI modules are shared with Ableton Live Assistant (Mantra)

Marko, 22.11.2026: "All the MIDI modules should only be actually in both places. We are sharing the modules ... they also share the settings. It's the same
thing, just in different views." The two modules now come from the public repo MANTRA_MIDI_MODULES (git submodule `shared/`, pinned; `shared.sha256`
checked by the workflow): one source for both apps, one on / off state `~/.config/mantra-midi-modules.json` (made from the old `midi-tools.json` and
`live-actions.json` keys), one engine (owner lock `~/.config/mantra-midi-owner.lock`): the app that is not the owner is a view and says
"runs in <the other app>". Alone, it owns the engines and shows no line. Same version, from the manifest's rules for an app's next update: the
updater at start (`app/Updater.swift`), no app ON / OFF (the window's ✕ quits), the version once, the title once (`enforceOneTitle`), the app's log in
~/Library/Logs/MIDI Tools (Mantra)/app.log. The download page is made from the release: `app.zip` of the workflow, signed "Mantra Apps",
`tools/make_dmg.sh` and `tools/deploy_site.sh` (no local build).
