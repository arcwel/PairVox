#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Swaps the last Release build into dist/PairVox.app and reopens it.
#
#   scripts/restart-app.sh              # quit PairVox (politely), copy the last Release build, reopen
#   scripts/restart-app.sh --build      # run scripts/build-app.sh first (the app must not be running)
#   scripts/restart-app.sh --dry-run    # say what would happen, change nothing
#   scripts/restart-app.sh --json       # one JSON object on stdout, nothing else
#   scripts/restart-app.sh --prune      # also remove every other PairVox.app and old phone build under the repo
#                                       # (alone: prune only, no restart), and report the running build against dist
# Exit codes: 0 done, 1 failed (see the message or the JSON "detail"), 2 bad usage.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=0 DRY=0 JSON=0 PRUNE=0 RESTART=1
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;; --dry-run) DRY=1 ;; --json) JSON=1 ;; --prune) PRUNE=1 ;;
    *) echo "usage: $0 [--build] [--prune] [--dry-run] [--json]" >&2; exit 2 ;;
  esac
done
# `--prune` alone (with or without --json / --dry-run) prunes and restarts nothing; with --build or on its own
# next to a restart it is one more step after the restart.
[[ $PRUNE -eq 1 && $BUILD -eq 0 && "$*" =~ ^(--prune|--json|--dry-run| )+$ && ! "$*" =~ --build ]] && RESTART=0

SRC=".build/xcode/Build/Products/Release/PairVox.app"
BIN="$ROOT/dist/PairVox.app/Contents/MacOS/PairVox"
# Only the copy in this checkout's dist/ counts: an anchored, literal match (pgrep -f is a regular expression).
running() { pgrep -f "^$(printf '%s' "$BIN" | sed 's/[][\.*^$+?(){}|/]/\\&/g')\$" >/dev/null; }
say() { [[ $JSON -eq 1 ]] || echo "$*"; }
was_running=false swapped=false launched=false
pruned=()

# Every PairVox.app and PairVoxPhone.app under the repo except dist/ (the running app), the restart source and the
# newest phone build: a stale copy is what `open` or a device install reaches for by mistake. Each is unregistered
# from Launch Services before it goes.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
prune() {
  local keep_mac="$ROOT/dist/PairVox.app" keep_src="$ROOT/$SRC" newest_phone="" a
  # Missing folders and an empty result are fine here; pipefail must not turn them into an exit.
  newest_phone=$({ find "$ROOT/.build" "$ROOT/.worktrees" -maxdepth 7 -type d -name PairVoxPhone.app -path "*iphoneos*" -print0 2>/dev/null || true; } \
    | { xargs -0 stat -f '%m %N' 2>/dev/null || true; } | sort -rn | head -1 | cut -d' ' -f2-)
  while IFS= read -r -d '' a; do
    [[ "$a" == "$keep_mac" || "$a" == "$keep_src" || "$a" == "$newest_phone" ]] && continue
    if [[ $DRY -eq 1 ]]; then say "Would remove ${a#"$ROOT"/}"; pruned+=("${a#"$ROOT"/}"); continue; fi
    "$LSREGISTER" -u "$a" >/dev/null 2>&1 || true
    find "$a" -delete 2>/dev/null || { finish false "could not remove $a" 1; }
    pruned+=("${a#"$ROOT"/}"); say "Removed ${a#"$ROOT"/}"
  done < <(find "$ROOT" -maxdepth 8 -type d \( -name PairVox.app -o -name PairVoxPhone.app \) -not -path "*/Contents/*" -print0 2>/dev/null)
  local pid cd_dist cd_run
  cd_dist=$({ codesign -dvvv "$keep_mac" 2>&1 || true; } | sed -n 's/^CDHash=//p')   # no dist yet: empty, not fatal
  pid=$(pgrep -f "^$(printf '%s' "$BIN" | sed 's/[][\.*^$+?(){}|/]/\\&/g')\$" | head -1 || true)
  if [[ -n "$pid" ]]; then
    cd_run=$({ codesign -dvvv +"$pid" 2>&1 || true; } | sed -n 's/^CDHash=//p')
    if [[ "$cd_run" == "$cd_dist" ]]; then say "Running app matches dist (CDHash $cd_dist)."; else say "Running app (CDHash $cd_run) is NOT the one in dist ($cd_dist): restart it."; fi
  else
    say "PairVox is not running; dist is ${cd_dist:+CDHash $cd_dist}${cd_dist:-missing}."
  fi
  if [[ -n "$newest_phone" ]]; then say "Phone build kept: ${newest_phone#"$ROOT"/}"; fi
}

# One JSON line at the end (or at the first failure); json_escape keeps the detail text valid JSON.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
finish() {   # ok detail exit-code
  if [[ $JSON -eq 1 ]]; then
    local list="" i
    for i in "${pruned[@]+"${pruned[@]}"}"; do list+="${list:+,}\"$(json_escape "$i")\""; done
    printf '{"ok":%s,"wasRunning":%s,"swapped":%s,"launched":%s,"pruned":[%s],"detail":"%s"}\n' "$1" "$was_running" "$swapped" "$launched" "$list" "$(json_escape "$2")"
  elif [[ "$1" == false ]]; then
    echo "$2" >&2
  fi
  exit "$3"
}
trap 'finish false "unexpected error near line $LINENO" 1' ERR

running && was_running=true
if [[ $RESTART -eq 0 ]]; then prune; finish true "pruned" 0; fi
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
[[ $PRUNE -eq 1 ]] && prune
finish true "ok" 0
