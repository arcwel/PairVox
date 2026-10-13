#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds dist/PairVox.app with Xcode (needed for MLX Metal shaders).
#
#   scripts/build-app.sh                       # ad-hoc signed, runs on this Mac
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
IDENTITY="${SIGN_IDENTITY:--}"
TEAM="${DEVELOPMENT_TEAM:-}"
VERSION_ARGS=()
[[ -n "${MARKETING_VERSION:-}" ]] && VERSION_ARGS+=(MARKETING_VERSION="$MARKETING_VERSION")

xcodegen generate --quiet

SIGN_ARGS=(CODE_SIGN_IDENTITY="$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  # Hardened runtime enforces library validation, and ad-hoc signatures have no Team ID,
  # so dyld refuses the embedded frameworks. Local builds run without it.
  SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=NO)
else
  SIGN_ARGS+=(CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp")
  [[ -n "$TEAM" ]] && SIGN_ARGS+=(DEVELOPMENT_TEAM="$TEAM")
fi

set -x
xcodebuild -project PairVox.xcodeproj -scheme PairVox -configuration "$CONFIG" \
  -derivedDataPath .build/xcode -destination "generic/platform=macOS" \
  -skipPackagePluginValidation -skipMacroValidation \
  "${SIGN_ARGS[@]}" "${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}" build | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
set +x

mkdir -p dist
rm -rf dist/PairVox.app
cp -R ".build/xcode/Build/Products/$CONFIG/PairVox.app" dist/

codesign --verify --deep --strict dist/PairVox.app && echo "Signature OK"
if find dist/PairVox.app -name "*.metallib" | grep -q .; then
  echo "MLX Metal library embedded: Kokoro voice available."
else
  echo "Warning: no .metallib found in the bundle; Kokoro will fall back to the system voice." >&2
fi
echo "Built dist/PairVox.app"
