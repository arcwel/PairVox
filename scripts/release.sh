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
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh VERSION}"
# The version names files and is passed to build tools, so it must look like one (a tag name is not trusted).
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]] || { echo "Not a version number: $VERSION" >&2; exit 2; }
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials)}"

MARKETING_VERSION="$VERSION" scripts/build-app.sh

DMG="dist/PairVox-$VERSION.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R dist/PairVox.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PairVox $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo
echo "Release ready: $DMG"
echo "sha256: $SHA"
echo "Update packaging/homebrew/pairvox.rb with version $VERSION and this sha256."
