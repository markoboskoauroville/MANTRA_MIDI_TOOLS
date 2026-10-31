#!/usr/bin/env python3
"""e16colour.py: give one knob of an OXI E16 scene a colour, in the scene file itself.

    python3 e16colour.py "<scene.oxie16>" <page 1-12> <knob 1-16> <colour 0-99>

Marko, 1.10.2026: the colour of each command's LED is chosen in MIDI to MK Control and MIDI to Key Stroke and
"saved to the scene". Plain MIDI carries no colour (MANTRA_MANIFEST oxi-e16.md section 5), so the colour lives
where the E16 keeps it: `pages[p].encoders[k].color` in the .oxie16 the OXI App saves. He then sends the scene
to the device from the OXI App.

The file is compact JSON that json.dumps(separators=(',', ':')) writes back byte for byte (checked on his
"S. 1" the same day), so only the one number changes. Before writing, the old file is copied to
~/.config/e16-scene-backups/, and the new one replaces it in one rename, so a crash cannot leave half a scene.
Prints the old colour, or an error on stderr with exit code 1.
"""
import json, os, shutil, sys, time


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: e16colour.py <scene.oxie16> <page 1-12> <knob 1-16> <colour 0-99>")
    path, page, knob, colour = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    if not (0 <= colour <= 99):
        sys.exit("the colour must be from 0 to 99")
    raw = open(path, encoding="utf-8").read()
    scene = json.loads(raw)
    if json.dumps(scene, separators=(",", ":"), ensure_ascii=False) != raw:
        sys.exit("this scene is not written the way the OXI App writes it: left untouched")
    enc = scene["pages"][page - 1]["encoders"][knob - 1]
    old = enc.get("color")
    if old == colour:
        print(old)
        return
    enc["color"] = colour

    backups = os.path.expanduser("~/.config/e16-scene-backups")
    os.makedirs(backups, exist_ok=True)
    name = os.path.basename(path)
    shutil.copy2(path, os.path.join(backups, time.strftime("%Y%m%d-%H%M%S-") + name + ".bak"))

    tmp = path + ".writing"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(scene, separators=(",", ":"), ensure_ascii=False))
    os.replace(tmp, path)
    print(old)


if __name__ == "__main__":
    main()
