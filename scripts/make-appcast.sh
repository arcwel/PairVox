#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Writes the Sparkle appcast for the DMGs in dist/, signed with the EdDSA private key in your login Keychain
# (generate_appcast reads it from there when no key file is given).
#
#   scripts/make-appcast.sh                     # dist/appcast.xml from dist/PairVox-*.dmg
#   scripts/make-appcast.sh --dry-run           # say what would happen; no key needed
#   DOWNLOAD_URL_PREFIX=https://github.com/arcwel/PairVox/releases/download/v0.1.0/ scripts/make-appcast.sh
#
# One-time setup (the private key never leaves your Keychain; back it up with `generate_keys -x FILE`):
#   generate_keys            prints the public key; put it in Sources/PairVoxApp/Info.plist as SUPublicEDKey
# Sparkle's command line tools come with the Sparkle package, which is NOT in project.yml yet (see docs/RELEASE.md):
# add it, run scripts/build-app.sh once so Xcode resolves it, and the tools appear under .build/xcode/SourcePackages.
# Exit codes: 0 done (or dry run), 1 a prerequisite is missing, 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: scripts/make-appcast.sh [--dry-run]" >&2; exit 2 ;;
esac

TOOLS="$(find .build/xcode/SourcePackages/artifacts -type d -path '*Sparkle*/bin' 2>/dev/null | head -1 || true)"
if [[ -z "$TOOLS" ]]; then
  echo "Sparkle's tools are not available: the Sparkle package is not in project.yml yet, or the build has not resolved it." >&2
  echo "See docs/RELEASE.md (\"In place\" table, Sparkle row) for how to add it." >&2
  [[ $DRY -eq 1 ]] && { echo "dry run: would run generate_appcast on dist/ once the tools exist."; exit 0; }
  exit 1
fi

shopt -s nullglob
DMGS=(dist/PairVox-*.dmg)
[[ ${#DMGS[@]} -gt 0 ]] || { echo "No dist/PairVox-*.dmg to list. Run scripts/release.sh first." >&2; exit 1; }

ARGS=()
[[ -n "${DOWNLOAD_URL_PREFIX:-}" ]] && ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")

if [[ $DRY -eq 1 ]]; then
  echo "dry run: would write dist/appcast.xml for: ${DMGS[*]}"
  echo "         with: $TOOLS/generate_appcast ${ARGS[*]-} dist   (key from the login Keychain)"
  if "$TOOLS/generate_appcast" --help >/dev/null 2>&1; then echo "         generate_appcast runs."; else echo "         generate_appcast did not start." >&2; fi
  exit 0
fi

"$TOOLS/generate_appcast" "${ARGS[@]+"${ARGS[@]}"}" dist
echo "Wrote dist/appcast.xml. Upload it to the address in SUFeedURL (Sources/PairVoxApp/Info.plist)."
