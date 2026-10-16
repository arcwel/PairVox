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
#     No certificate or notary account needed: builds ad-hoc signed, makes the DMG, then checks everything that
#     notarization would check (bundle structure, Info.plist, entitlements, no unsigned or extra Mach-O files,
#     hardened runtime off because the signature is ad-hoc) and prints what is still missing for a real release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh VERSION [--dry-run]}"
DRY=0
[[ "${2:-}" == "--dry-run" ]] && DRY=1
# The version names files and is passed to build tools, so it must look like one (a tag name is not trusted).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "Not a version number: $VERSION" >&2; exit 2; }
if [[ $DRY -eq 0 ]]; then
  : "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials)}"
fi

OUT=dist
if [[ $DRY -eq 1 ]]; then
  # A dry run never touches dist/, where the app you may be running lives.
  OUT=.build/release-dry
  MARKETING_VERSION="$VERSION" SIGN_IDENTITY="-" DIST_DIR="$OUT" scripts/build-app.sh >/dev/null
else
  MARKETING_VERSION="$VERSION" scripts/build-app.sh
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
    [[ -n "$v" ]] && ok "$key = $v" || problem "$key missing from Info.plist"
  done
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")" == "$VERSION" ]] || problem "CFBundleShortVersionString is not $VERSION"
  FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null || true)"
  EDKEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" 2>/dev/null || true)"
  if [[ -n "$FEED" && -n "$EDKEY" ]]; then ok "Sparkle configured (SUFeedURL set, SUPublicEDKey set)"; else echo "  todo  Sparkle is off: SUFeedURL and SUPublicEDKey are empty (fine before the first release)"; fi

  # 3. Entitlements: hardened-runtime exceptions must be the known ones and nothing more. Xcode adds get-task-allow
  #    (debugger attach) to every ad-hoc signature; a Developer ID signature must not carry it or notarization fails.
  # (captured first: with pipefail, grep -q closing the pipe early would make the pipeline fail)
  ADHOC=0; SIG="$(codesign -dv "$APP" 2>&1 || true)"; [[ "$SIG" == *"Signature=adhoc"* ]] && ADHOC=1
  ENT="$(codesign -d --entitlements :- "$APP" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<[^>]*>//g' | grep -v '^com.apple.security.get-task-allow$' | sort | tr '\n' ' ')"
  if [[ "$ENT" == "com.apple.security.automation.apple-events com.apple.security.device.audio-input " ]]; then ok "entitlements: $ENT"; else problem "unexpected entitlements: ${ENT:-none}"; fi
  if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    if [[ $ADHOC -eq 1 ]]; then echo "  info  get-task-allow is present because the signature is ad-hoc; a Developer ID build drops it"; else problem "get-task-allow in a Developer ID build (notarization rejects it)"; fi
  fi

  # 4. No Mach-O file in the bundle is unsigned (notarization rejects any), and nothing stray is embedded.
  UNSIGNED=0
  while IFS= read -r f; do
    if file -b "$f" | grep -q "Mach-O"; then codesign -dv "$f" >/dev/null 2>&1 || { echo "        unsigned: ${f#$APP/}"; UNSIGNED=$((UNSIGNED + 1)); }; fi
  done < <(find "$APP" -type f)
  [[ $UNSIGNED -eq 0 ]] && ok "every Mach-O file is signed" || problem "$UNSIGNED unsigned Mach-O files"
  FW="$(ls "$APP/Contents/Frameworks" 2>/dev/null | tr '\n' ' ')"
  echo "  info  frameworks: ${FW:-none}"

  # 5. What a real release still needs on this Mac.
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" && ok "a Developer ID Application certificate is in the keychain" || echo "  todo  no Developer ID Application certificate in the keychain (Apple Developer Program needed)"
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-pairvox-notary}" >/dev/null 2>&1 && ok "notary profile ${NOTARY_PROFILE:-pairvox-notary} works" || echo "  todo  no notary profile (xcrun notarytool store-credentials pairvox-notary ...)"
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
