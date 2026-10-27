#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds dist/PairVox.app with Xcode (needed for MLX Metal shaders).
#
#   scripts/build-app.sh                       # signed with the Mac's Apple Development certificate (ad-hoc without one)
#   SIGN_IDENTITY=- scripts/build-app.sh       # ad-hoc: macOS asks for the microphone again after every such build
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   DEVELOPMENT_TEAM=TEAMID scripts/build-app.sh   # distributable build
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "The app builds on macOS only. On Linux, use: swift build && swift test" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: Kokoro (MLX) needs Apple Silicon; on Intel the system voice is used." >&2
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }

CONFIG="${CONFIG:-Release}"
# A local build needs a signature that stays the same from one build to the next: macOS keys the microphone
# permission (and the Keychain) on the code identity, and an ad-hoc signature is the hash of that one binary, so
# every ad-hoc rebuild is a new app that asks for the microphone again and sits in that prompt until someone
# clicks. An Apple Development certificate (free account, from Xcode) gives a stable identity; it is picked up
# when present. SIGN_IDENTITY="-" forces ad-hoc; see docs/DEV_ENVIRONMENT.md.
AUTO_TEAM=""
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # The keychain keeps old copies of the certificate that Xcode rejects as "not valid for code signing" (revoked
  # when it issued the next one), and `codesign` cannot tell them apart. So the script only finds the team (the
  # certificate's OU) and lets Xcode pick the valid copy, as it does for the iPhone build.
  AUTO_TEAM=$(security find-certificate -a -c "Apple Development:" -p 2>/dev/null \
    | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{print c | "openssl x509 -noout -subject 2>/dev/null"; close("openssl x509 -noout -subject 2>/dev/null")}' \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | sort | uniq -c | sort -rn | awk 'NR==1 {print $2}')
  if [[ -n "$AUTO_TEAM" ]]; then
    echo "Signing with the Apple Development certificate of team $AUTO_TEAM (set SIGN_IDENTITY=- for ad-hoc)."
  else
    echo "Warning: no Apple Development certificate; ad-hoc signing, and macOS will ask for the microphone again after this build." >&2
  fi
fi
IDENTITY="${SIGN_IDENTITY:--}"
TEAM="${DEVELOPMENT_TEAM:-$AUTO_TEAM}"
VERSION_ARGS=()
[[ -n "${MARKETING_VERSION:-}" ]] && VERSION_ARGS+=(MARKETING_VERSION="$MARKETING_VERSION")
# CFBundleVersion: updates are ordered by it, so a release passes a number that grows (scripts/release.sh does).
[[ -n "${BUILD_NUMBER:-}" ]] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

xcodegen generate --quiet

SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY")
if [[ -n "$AUTO_TEAM" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM")
elif [[ "$IDENTITY" == "-" ]]; then
  # Hardened runtime enforces library validation, and ad-hoc signatures have no Team ID, so dyld would refuse the
  # embedded frameworks. Xcode builds without it; the app itself is re-signed below.
  SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=NO)
else
  SIGN_ARGS+=(CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp")
  [[ -n "$TEAM" ]] && SIGN_ARGS+=(DEVELOPMENT_TEAM="$TEAM")
fi

set -x
xcodebuild -project PairVox.xcodeproj -scheme PairVox -configuration "$CONFIG" \
  -derivedDataPath .build/xcode -destination "generic/platform=macOS" \
  "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" build | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
set +x

# DIST_DIR lets a dry run or a test build land somewhere other than dist/, where the app you are running lives.
DIST="${DIST_DIR:-dist}"
PRODUCT=".build/xcode/Build/Products/$CONFIG/PairVox.app"
[[ -d "$PRODUCT" ]] || { echo "No $PRODUCT after the build; $DIST/PairVox.app was not touched." >&2; exit 1; }
mkdir -p "$DIST"
# Copied beside the old app first, so a failed copy (a full disk) leaves the old one in place.
rm -rf "$DIST/.PairVox.new" "$DIST/.PairVox.old"
cp -R "$PRODUCT" "$DIST/.PairVox.new"
# The old app is moved aside before the new one goes in, as restart-app.sh does, so dist/ is never without one.
[[ -d "$DIST/PairVox.app" ]] && mv "$DIST/PairVox.app" "$DIST/.PairVox.old"
mv "$DIST/.PairVox.new" "$DIST/PairVox.app"
rm -rf "$DIST/.PairVox.old"

if [[ -z "$AUTO_TEAM" && "$IDENTITY" == "-" ]]; then
  # Ad-hoc (also the published DMG until there is a Developer ID): the app is re-signed with the hardened runtime,
  # so no debugger can attach and DYLD_* is ignored, and with explicit entitlements, which drops the get-task-allow
  # Xcode adds (audit run 9: the 0.1.0-beta.1 DMG carried it). The ad-hoc entitlements add only
  # disable-library-validation, which the frameworks need without a Team ID.
  codesign --force --sign - --options runtime --entitlements Sources/PairVoxApp/PairVox-adhoc.entitlements "$DIST/PairVox.app"
fi
# A failed check must stop the script: as `verify && echo` it was ignored by set -e (stability audit, 2026-10-26).
codesign --verify --deep --strict "$DIST/PairVox.app" || { echo "The signature of $DIST/PairVox.app failed its check." >&2; exit 1; }
echo "Signature OK"
METALLIBS="$(find "$DIST/PairVox.app" -name "*.metallib" || true)"
if [[ -n "$METALLIBS" ]]; then
  echo "MLX Metal library embedded: Kokoro voice available."
else
  echo "Warning: no .metallib found in the bundle; Kokoro will fall back to the system voice." >&2
fi
echo "Built $DIST/PairVox.app"
