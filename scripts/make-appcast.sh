#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Writes the Sparkle appcast for the DMGs in dist/ (signed with the EdDSA key in your Keychain).
#
#   scripts/make-appcast.sh                     # dist/appcast.xml from dist/PairVox-*.dmg
#   scripts/make-appcast.sh --dry-run           # say what would happen; no key needed
#   DOWNLOAD_URL_PREFIX=https://github.com/arcwel/PairVox/releases/download/v0.1.0/ scripts/make-appcast.sh
#
# One-time setup (the private key never leaves your Keychain; back it up with `generate_keys -x FILE`):
#   generate_keys            prints the public key; put it in Sources/PairVoxApp/Info.plist as SUPublicEDKey
# Sparkle's tools come with the package the Xcode build resolves (scripts/build-app.sh runs it first).
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

TOOLS="$(find .build/xcode/SourcePackages/artifacts -type d -path '*Sparkle*/bin' 2>/dev/null | head -1 || true)"
if [[ -z "$TOOLS" ]]; then
  echo "Sparkle's tools are not here yet: run scripts/build-app.sh once (it resolves the Sparkle package)." >&2
  [[ $DRY -eq 1 ]] && { echo "dry run: would run generate_appcast on dist/ after that."; exit 0; }
  exit 1
fi

shopt -s nullglob
DMGS=(dist/PairVox-*.dmg)
[[ ${#DMGS[@]} -gt 0 ]] || { echo "No dist/PairVox-*.dmg to list. Run scripts/release.sh first." >&2; exit 1; }

ARGS=(--ed-key-file -)
[[ -n "${DOWNLOAD_URL_PREFIX:-}" ]] && ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")

if [[ $DRY -eq 1 ]]; then
  echo "dry run: would write dist/appcast.xml for: ${DMGS[*]}"
  echo "         with: $TOOLS/generate_appcast ${ARGS[*]} dist"
  "$TOOLS/generate_appcast" --help >/dev/null 2>&1 && echo "         generate_appcast runs." || echo "         generate_appcast did not start." >&2
  exit 0
fi

# The key is read from the Keychain item generate_keys made; nothing is written to disk but the appcast.
"$TOOLS/generate_appcast" "${ARGS[@]}" dist
echo "Wrote dist/appcast.xml. Upload it to the address in SUFeedURL (Sources/PairVoxApp/Info.plist)."
