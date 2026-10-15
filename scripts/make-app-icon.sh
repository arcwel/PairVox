#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Turns an icon SVG into the app's icon set (Resources/Assets.xcassets/AppIcon.appiconset) and docs/icon.png.
#
#   scripts/make-app-icon.sh docs/icon-concepts/pairvox-icon-3-vee.svg            # install it
#   scripts/make-app-icon.sh docs/icon-concepts/pairvox-icon-3-vee.svg --dry-run  # list what would be written
#   scripts/make-app-icon.sh ICON.svg --out DIR                                    # write the set somewhere else
#   scripts/make-app-icon.sh docs/icon-concepts/pairvox-icon-ios-2a.svg --ios     # the iPhone app's icon (one 1024 px square, no alpha)
# Needs ImageMagick (`magick`). The SVG must be 1024x1024 with flat shapes (no filters).
# Exit codes: 0 done, 1 failed, 2 bad usage.
set -euo pipefail
START="$PWD"
cd "$(dirname "$0")/.."

SVG="" DRY=0 IOS=0 OUT="Resources/Assets.xcassets/AppIcon.appiconset" OUT_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --ios) IOS=1 ;;
    --out) OUT="${2:?--out needs a folder}"; OUT_SET=1; shift ;;
    -*) echo "usage: $0 ICON.svg [--dry-run] [--out DIR]" >&2; exit 2 ;;
    *) SVG="$1" ;;
  esac
  shift
done
[[ -n "$SVG" ]] || { echo "usage: $0 ICON.svg [--dry-run] [--out DIR]" >&2; exit 2; }
# Paths given on the command line are relative to where the command was run, not to the repository.
[[ $IOS -eq 1 && $OUT_SET -eq 0 ]] && OUT="ios/PairVoxPhone/Assets.xcassets/AppIcon.appiconset"
[[ "$SVG" = /* ]] || SVG="$START/$SVG"
[[ "$OUT" = /* || $OUT_SET -eq 0 ]] || OUT="$START/$OUT"
[[ -f "$SVG" ]] || { echo "No such file: $SVG" >&2; exit 1; }
command -v magick >/dev/null || { echo "Install ImageMagick first: brew install imagemagick" >&2; exit 1; }
grep -q 'viewBox="0 0 1024 1024"' "$SVG" || { echo "$SVG is not a 1024x1024 icon" >&2; exit 1; }

if [[ $IOS -eq 1 ]]; then
  if [[ $DRY -eq 1 ]]; then echo "would write $OUT/icon-1024.png, $OUT/Contents.json and the catalog's Contents.json"; exit 0; fi
  mkdir -p "$OUT"
  # An iPhone icon must not have transparency, so the alpha channel is removed.
  magick -background none -density 96 "$SVG" -resize 1024x1024 -alpha off "$OUT/icon-1024.png"
  cat > "$OUT/Contents.json" <<'J'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
J
  printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$(dirname "$OUT")/Contents.json"
  echo "Wrote the iPhone icon to $OUT"
  exit 0
fi

# size@scale -> pixel size, the ten files a macOS icon set needs
declare -a FILES=("16x16:16" "16x16@2x:32" "32x32:32" "32x32@2x:64" "128x128:128" "128x128@2x:256"
                  "256x256:256" "256x256@2x:512" "512x512:512" "512x512@2x:1024")
if [[ $DRY -eq 1 ]]; then
  for entry in "${FILES[@]}"; do echo "would write $OUT/icon_${entry%%:*}.png (${entry##*:} px)"; done
  [[ $OUT_SET -eq 0 ]] && echo "would write docs/icon.png (512 px)"
  exit 0
fi
mkdir -p "$OUT"
for entry in "${FILES[@]}"; do
  magick -background none -density 96 "$SVG" -resize "${entry##*:}x${entry##*:}" "$OUT/icon_${entry%%:*}.png"
done
[[ $OUT_SET -eq 0 ]] && magick -background none -density 96 "$SVG" -resize 512x512 docs/icon.png
echo "Wrote the icon set to $OUT"
