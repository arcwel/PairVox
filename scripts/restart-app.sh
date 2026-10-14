#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Swaps the last Release build into dist/PairVox.app and reopens it.
#
#   scripts/restart-app.sh              # quit PairVox (politely), copy the last Release build, reopen
#   scripts/restart-app.sh --build      # run scripts/build-app.sh first (the app must not be running)
#   scripts/restart-app.sh --dry-run    # say what would happen, change nothing
#   scripts/restart-app.sh --json       # one JSON object on stdout, nothing else
# Exit codes: 0 done, 1 failed (see the message or the JSON "detail"), 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=0 DRY=0 JSON=0
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;; --dry-run) DRY=1 ;; --json) JSON=1 ;;
    *) echo "usage: $0 [--build] [--dry-run] [--json]" >&2; exit 2 ;;
  esac
done

SRC=".build/xcode/Build/Products/Release/PairVox.app"
BIN="$ROOT/dist/PairVox.app/Contents/MacOS/PairVox"
# Only the copy in this checkout's dist/ counts: an anchored, literal match (pgrep -f is a regular expression).
running() { pgrep -f "^$(printf '%s' "$BIN" | sed 's/[][\.*^$+?(){}|/]/\\&/g')\$" >/dev/null; }
say() { [[ $JSON -eq 1 ]] || echo "$*"; }
was_running=false swapped=false launched=false

# One JSON line at the end (or at the first failure); json_escape keeps the detail text valid JSON.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
finish() {   # ok detail exit-code
  if [[ $JSON -eq 1 ]]; then
    printf '{"ok":%s,"wasRunning":%s,"swapped":%s,"launched":%s,"detail":"%s"}\n' "$1" "$was_running" "$swapped" "$launched" "$(json_escape "$2")"
  elif [[ "$1" == false ]]; then
    echo "$2" >&2
  fi
  exit "$3"
}
trap 'finish false "unexpected error near line $LINENO" 1' ERR

running && was_running=true
if [[ $BUILD -eq 1 ]]; then
  $was_running && finish false "Quit PairVox first: --build replaces the running app." 1
  if [[ $DRY -eq 1 ]]; then say "Would run scripts/build-app.sh"; finish true "dry run" 0; fi
  scripts/build-app.sh >/dev/null 2>&1 || finish false "scripts/build-app.sh failed" 1
  SRC="dist/PairVox.app"
fi
[[ -d "$SRC" ]] || finish false "No build at $SRC. Run scripts/build-app.sh." 1
# Check the new build before anything is quit or deleted.
codesign --verify --deep --strict "$SRC" 2>/dev/null || finish false "The build at $SRC is incomplete or its signature is broken; nothing was changed." 1

if [[ $DRY -eq 1 ]]; then
  say "PairVox is $($was_running && echo running || echo not running). Would $($was_running && echo 'quit it, ')copy $SRC to dist/PairVox.app and open it."
  finish true "dry run" 0
fi

if $was_running; then
  quit_error=$(osascript -e 'tell application "PairVox" to quit' 2>&1 >/dev/null) || true
  for _ in $(seq 1 30); do running || break; sleep 0.5; done
  if running; then
    finish false "PairVox did not quit within 15 seconds (it may be waiting on a dialog${quit_error:+; osascript said: $quit_error}). Nothing was changed." 1
  fi
fi

if [[ "$SRC" != "dist/PairVox.app" ]]; then
  # Copy beside the old app, verify, then swap, so a failed copy never leaves dist without a working app.
  mkdir -p dist
  rm -rf dist/.PairVox.new
  cp -R "$SRC" dist/.PairVox.new
  codesign --verify --deep --strict dist/.PairVox.new 2>/dev/null || { rm -rf dist/.PairVox.new; finish false "The copy failed its signature check; dist/PairVox.app was not touched." 1; }
  rm -rf dist/PairVox.app
  mv dist/.PairVox.new dist/PairVox.app
fi
swapped=true
open dist/PairVox.app
for _ in $(seq 1 30); do running && { launched=true; break; }; sleep 0.5; done
$launched || finish false "PairVox did not start within 15 seconds." 1
say "PairVox reopened (was $($was_running && echo running || echo 'not running'))."
finish true "ok" 0
