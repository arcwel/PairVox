#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds, signs, notarizes and packages a release DMG.
#
# Prerequisites (once):
#   - A "Developer ID Application" certificate in your keychain
#   - xcrun notarytool store-credentials pairvox-notary --apple-id you@example.com --team-id TEAMID
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" DEVELOPMENT_TEAM=TEAMID \
#   NOTARY_PROFILE=pairvox-notary scripts/release.sh 0.1.0
#
#   scripts/release.sh 0.1.0 --dry-run
#     No certificate or notary account needed: builds ad-hoc signed into .build/release-dry (never dist/), makes the
#     DMG, then checks what it can of what notarization would check (every signature valid, Info.plist keys and a
#     build number, the entitlements, no unsigned Mach-O file) and prints what is still missing for a real release.
#     The only argument after the version that is accepted is --dry-run; anything else is an error, so a typo can
#     never turn into a real release.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: scripts/release.sh VERSION [--dry-run]" >&2; exit 2; }
VERSION="$1"
DRY=0
case "${2:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "Unknown argument: $2 (the only option is --dry-run)" >&2; exit 2 ;;
esac
# The version names files and is passed to build tools, so it must look like one (a tag name is not trusted).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "Not a version number: $VERSION" >&2; exit 2; }
if [[ $DRY -eq 0 ]]; then
  : "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials)}"
fi

# CFBundleVersion must grow with every release (Sparkle orders updates by it); the number of commits does, on main.
BUILD_NUMBER="$(git rev-list --count HEAD)"

# The entitlements a signed app carries, sorted on one line. Each stage tolerates "nothing found": with pipefail an
# app without entitlements must not abort the script.
entitlement_keys() {
  { codesign -d --entitlements :- "$1" 2>/dev/null || true; } | { grep -o '<key>[^<]*</key>' || true; } | sed 's/<[^>]*>//g' | sort | tr '\n' ' '
}
EXPECTED_ENTITLEMENTS="com.apple.security.automation.apple-events com.apple.security.device.audio-input "

OUT=dist
if [[ $DRY -eq 1 ]]; then
  # A dry run never touches dist/, where the app you may be running lives.
  OUT=.build/release-dry
  MARKETING_VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="-" DIST_DIR="$OUT" scripts/build-app.sh >/dev/null
else
  MARKETING_VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" scripts/build-app.sh
  # What notarization would reject, caught before anything is signed or uploaded.
  ENT_ALL="$(entitlement_keys "$OUT/PairVox.app")"
  [[ "$ENT_ALL" != *"com.apple.security.get-task-allow"* ]] || { echo "$OUT/PairVox.app carries get-task-allow (debugger attach); notarization rejects it. Not releasing." >&2; exit 1; }
  [[ "$ENT_ALL" == "$EXPECTED_ENTITLEMENTS" ]] || { echo "Unexpected entitlements in $OUT/PairVox.app: ${ENT_ALL:-none}. Not releasing." >&2; exit 1; }
fi

DMG="$OUT/PairVox-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$OUT/PairVox.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PairVox $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ $DRY -eq 1 ]]; then
  APP="$OUT/PairVox.app"
  PROBLEMS=0
  problem() { echo "  FAIL  $1"; PROBLEMS=$((PROBLEMS + 1)); }
  ok() { echo "  ok    $1"; }
  echo "release dry run: $DMG ($(du -h "$DMG" | cut -f1))"

  # 1. Every signature in the bundle is valid and the structure is what notarization expects.
  if codesign --verify --deep --strict "$APP" 2>/dev/null; then ok "codesign --verify --deep --strict"; else problem "codesign --verify --deep --strict (run it for details)"; fi

  # 2. Info.plist carries what the notary service and Sparkle need.
  PLIST="$APP/Contents/Info.plist"
  for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    v="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then ok "$key = $v"; else problem "$key missing from Info.plist"; fi
  done
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")" == "$VERSION" ]] || problem "CFBundleShortVersionString is not $VERSION"
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")" == "$BUILD_NUMBER" ]] || problem "CFBundleVersion is not the build number $BUILD_NUMBER (Sparkle could not tell releases apart)"
  FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null || true)"
  EDKEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || true)"
  if [[ -n "$FEED" && -n "$EDKEY" ]]; then ok "Sparkle configured (SUFeedURL set, SUPublicEDKey set)"; else echo "  todo  Sparkle is off: SUFeedURL and SUPublicEDKey are empty (fine before the first release)"; fi

  # 3. Entitlements: the known ones and nothing more. The ad-hoc build (published until there is a Developer ID)
  #    may add only disable-library-validation; get-task-allow (debugger attach) is a failure, as in a real release,
  #    and so is a missing hardened runtime (audit run 9: the 0.1.0-beta.1 DMG had both problems).
  ENT_ALL="$(entitlement_keys "$APP")"
  ADHOC_EXPECTED="com.apple.security.automation.apple-events com.apple.security.cs.disable-library-validation com.apple.security.device.audio-input "
  if [[ "$ENT_ALL" == "$EXPECTED_ENTITLEMENTS" || "$ENT_ALL" == "$ADHOC_EXPECTED" ]]; then ok "entitlements: $ENT_ALL"; else problem "unexpected entitlements: ${ENT_ALL:-none}"; fi
  if [[ "$ENT_ALL" == *"com.apple.security.get-task-allow"* ]]; then problem "get-task-allow is present: any process of the same user could attach a debugger"; fi
  # Captured first: with pipefail, grep -q closing the pipe early can make the pipeline report failure.
  SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
  if [[ "$SIGNATURE" == *"flags="*"runtime"* ]]; then ok "hardened runtime"; else problem "no hardened runtime on $APP"; fi

  # 4. No Mach-O file in the bundle is unsigned (notarization rejects any), and nothing stray is embedded.
  UNSIGNED=0
  while IFS= read -r f; do
    kind="$(file -b "$f" || true)"
    if [[ "$kind" == *"Mach-O"* ]]; then codesign -dv "$f" >/dev/null 2>&1 || { echo "        unsigned: ${f#"$APP"/}"; UNSIGNED=$((UNSIGNED + 1)); }; fi
  done < <(find "$APP" -type f)
  if [[ $UNSIGNED -eq 0 ]]; then ok "every Mach-O file is signed"; else problem "$UNSIGNED unsigned Mach-O files"; fi
  FW="$(ls "$APP/Contents/Frameworks" 2>/dev/null | tr '\n' ' ' || true)"
  echo "  info  frameworks: ${FW:-none}"

  # 5. What a real release still needs on this Mac. (Output is captured first: with pipefail, grep -q closing the
  #    pipe early can make the pipeline report failure.)
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ "$IDENTITIES" == *"Developer ID Application"* ]]; then ok "a Developer ID Application certificate is in the keychain"; else echo "  todo  no Developer ID Application certificate in the keychain (Apple Developer Program needed)"; fi
  if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-pairvox-notary}" >/dev/null 2>&1; then ok "notary profile ${NOTARY_PROFILE:-pairvox-notary} works"; else echo "  todo  no notary profile (xcrun notarytool store-credentials pairvox-notary ...)"; fi
  if spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1; then ok "Gatekeeper accepts the DMG"; else echo "  info  Gatekeeper rejects the ad-hoc DMG, as expected before signing and notarization"; fi

  echo
  if [[ $PROBLEMS -eq 0 ]]; then echo "Dry run passed: the bundle is ready for signing once the certificate and notary account exist."; else echo "Dry run found $PROBLEMS problems to fix before a release."; exit 1; fi
  exit 0
fi

codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo
echo "Release ready: $DMG"
echo "sha256: $SHA"
echo "Update packaging/homebrew/pairvox.rb with version $VERSION and this sha256."
