#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Turns an icon SVG into the app's icon set (Resources/Assets.xcassets/AppIcon.appiconset) and docs/icon.png.
#
#   scripts/make-app-icon.sh docs/icon-concepts/pairvox-icon-3-vee.svg            # install it
#   scripts/make-app-icon.sh docs/icon-concepts/pairvox-icon-3-vee.svg --dry-run  # list what would be written
#   scripts/make-app-icon.sh ICON.svg --out DIR                                    # write the set somewhere else
# Needs ImageMagick (`magick`). The SVG must be 1024x1024 with flat shapes (no filters).
# Exit codes: 0 done, 1 failed, 2 bad usage.
set -euo pipefail
START="$PWD"
cd "$(dirname "$0")/.."

SVG="" DRY=0 OUT="Resources/Assets.xcassets/AppIcon.appiconset"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --out) OUT="${2:?--out needs a folder}"; shift ;;
    -*) echo "usage: $0 ICON.svg [--dry-run] [--out DIR]" >&2; exit 2 ;;
    *) SVG="$1" ;;
  esac
  shift
done
[[ -n "$SVG" ]] || { echo "usage: $0 ICON.svg [--dry-run] [--out DIR]" >&2; exit 2; }
# Paths given on the command line are relative to where the command was run, not to the repository.
[[ "$SVG" = /* ]] || SVG="$START/$SVG"
[[ "$OUT" = /* || "$OUT" == "Resources/Assets.xcassets/AppIcon.appiconset" ]] || OUT="$START/$OUT"
[[ -f "$SVG" ]] || { echo "No such file: $SVG" >&2; exit 1; }
command -v magick >/dev/null || { echo "Install ImageMagick first: brew install imagemagick" >&2; exit 1; }
grep -q 'viewBox="0 0 1024 1024"' "$SVG" || { echo "$SVG is not a 1024x1024 icon" >&2; exit 1; }

# size@scale -> pixel size, the ten files a macOS icon set needs
declare -a FILES=("16x16:16" "16x16@2x:32" "32x32:32" "32x32@2x:64" "128x128:128" "128x128@2x:256"
                  "256x256:256" "256x256@2x:512" "512x512:512" "512x512@2x:1024")
if [[ $DRY -eq 1 ]]; then
  for entry in "${FILES[@]}"; do echo "would write $OUT/icon_${entry%%:*}.png (${entry##*:} px)"; done
  [[ "$OUT" == "Resources/Assets.xcassets/AppIcon.appiconset" ]] && echo "would write docs/icon.png (512 px)"
  exit 0
fi
mkdir -p "$OUT"
for entry in "${FILES[@]}"; do
  magick -background none -density 96 "$SVG" -resize "${entry##*:}x${entry##*:}" "$OUT/icon_${entry%%:*}.png"
done
[[ "$OUT" == "Resources/Assets.xcassets/AppIcon.appiconset" ]] && magick -background none -density 96 "$SVG" -resize 512x512 docs/icon.png
echo "Wrote the icon set to $OUT"
