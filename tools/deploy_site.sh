#!/bin/bash
# deploy_site.sh: https://mantramiditools.pages.dev (site/public) on Cloudflare Pages. The account id and token are read
# from Marko's API folder, never printed. The newest DMG (build/MIDIToolsMantra-<V>.dmg, made by tools/make_dmg.sh) goes behind
# the one address that never changes, download/MIDITools.dmg (MANTRA_MANIFEST modules/download-always-latest.md, 1.11.2026);
# the version and the size on the page are written in here from VERSION, never by hand. build.sh runs this by itself.
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/Common.swift)
DMG="build/MIDIToolsMantra-$V.dmg"; FIXED="download/MIDITools.dmg"; P=site/public
[ -f "$DMG" ] || { echo "no $DMG: run build.sh (or tools/make_dmg.sh)"; exit 1; }
BYTES=$(stat -f %z "$DMG")
[ "$BYTES" -lt 26214400 ] || { echo "$DMG is $BYTES bytes, over Cloudflare Pages' 25 MB: a GitHub release is needed (download-always-latest.md)"; exit 1; }
rm -f $P/*.dmg; mkdir -p $P/download; cp "$DMG" "$P/$FIXED"
# old shared links (the versioned names) keep working
touch $P/_redirects
grep -qF "/MIDIToolsMantra-* " $P/_redirects || echo "/MIDIToolsMantra-* /download/MIDITools.dmg 301" >> $P/_redirects
grep -qF "/MantraMIDITools-* " $P/_redirects || echo "/MantraMIDITools-* /download/MIDITools.dmg 301" >> $P/_redirects
# the version line: <span id="app-version"> and <span id="app-size"> written from this run
MB=$(python3 -c "print(f'{$BYTES/1048576:.1f}')")
sed -i '' -E "s#<span id=\"app-version\">[^<]*</span>#<span id=\"app-version\">$V</span>#g; s#<span id=\"app-size\">[^<]*</span>#<span id=\"app-size\">$MB MB</span>#g" $P/index.html
grep -q "href=\"$FIXED\"" $P/index.html || { echo "index.html does not link $FIXED"; exit 1; }
grep -q "<span id=\"app-version\">$V</span>" $P/index.html || { echo "index.html has no <span id=\"app-version\">"; exit 1; }
# every page with the donation bowl is search-engine optimised (Marko, 31.10.2026)
python3 ~/Developer/MANTRA_MANIFEST/kits/seo/seo_app_page.py $P --url https://mantramiditools.pages.dev --name "MIDI Tools (Mantra)" --category MultimediaApplication --keywords "MIDI to keystroke mac, Mackie Control emulator, Ableton Live MIDI controller, MIDI to keyboard, MCU, free MIDI tool" --version "$V" --download "$FIXED"
! grep -q "MIDIToolsMantra-[0-9]" $P/index.html || { echo "index.html still names a versioned DMG"; exit 1; }
eval "$(python3 - <<'PY'
import re,os
raw=open(os.path.expanduser('~/Downloads/API/Cloudflare.api.txt')).read()
acc=re.search(r'dash\.cloudflare\.com/([0-9a-f]{32})', raw).group(1)
tok=[l.strip() for l in raw.splitlines() if re.fullmatch(r'[A-Za-z0-9_\-]{30,}', l.strip())][-1]
print(f"export CLOUDFLARE_ACCOUNT_ID={acc}; export CLOUDFLARE_API_TOKEN={tok}")
PY
)"
npx --yes wrangler@3 pages project create mantramiditools --production-branch main >/dev/null 2>&1 || true
npx --yes wrangler@3 pages deploy $P --project-name mantramiditools --branch main --commit-dirty=true 2>&1 | grep -v -i "token\|account" | tail -3
echo "published v$V ($MB MB): https://mantramiditools.pages.dev/$FIXED"
