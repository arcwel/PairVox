#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# One-click update for a PairVox built from this checkout: builds the current code while the app keeps running, swaps
# the new build in, reopens it and checks the launch. The app it replaced becomes dist/PairVox.previous.app only once
# the new one has passed that check, so the previous copy is always one that worked; a new build that fails it is
# rolled back at once.
#
#   scripts/pv-install.sh               # build what is checked out, install it, reopen, check the launch
#   scripts/pv-install.sh --pull        # first bring the current branch up to date (fast-forward only)
#   scripts/pv-install.sh --dry-run     # say what would happen, change nothing
#   scripts/pv-install.sh --json        # one JSON object on stdout at the end
#   scripts/pv-install.sh --rollback    # put dist/PairVox.previous.app back and reopen it
# Exit codes: 0 installed (or rolled back), 1 failed (the app that was installed is running again), 2 bad usage,
# 3 another install is already running.
#
# The app's "Install Latest Build" menu item runs `scripts/pv-install.sh --pull --json`, with its output in
# ~/Library/Logs/PairVox/update.log, under nohup: the swap quits the app that started it.
set -euo pipefail
cd "$(dirname "$0")/.."

PULL=0 DRY=0 JSON=0 ROLLBACK=0
for arg in "$@"; do
  case "$arg" in
    --pull) PULL=1 ;; --dry-run) DRY=1 ;; --json) JSON=1 ;; --rollback) ROLLBACK=1 ;;
    *) echo "usage: scripts/pv-install.sh [--pull] [--dry-run] [--json] [--rollback]" >&2; exit 2 ;;
  esac
done

LOCK=.build/install.lock
steps=()
say() { [[ $JSON -eq 1 ]] || echo "$*"; steps+=("$*"); }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
finish() {   # ok detail exit-code
  if [[ $JSON -eq 1 ]]; then
    local list="" s
    for s in "${steps[@]+"${steps[@]}"}"; do list+="${list:+,}\"$(json_escape "$s")\""; done
    printf '{"ok":%s,"commit":"%s","steps":[%s],"detail":"%s"}\n' "$1" "$(git rev-parse --short HEAD 2>/dev/null)" "$list" "$(json_escape "$2")"
  elif [[ "$1" == false ]]; then
    echo "$2" >&2
  fi
  exit "$3"
}
trap 'finish false "unexpected error near line $LINENO" 1' ERR

# One install at a time: two would share .build/xcode and both swap dist/.
mkdir -p .build
if [[ $DRY -eq 0 ]]; then
  mkdir "$LOCK" 2>/dev/null || finish false "Another install is already running (remove $LOCK if it is not)." 3
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
fi

# launch-check exits 1 for a failed launch; only its run id is wanted here, so its status must not stop the script.
newest_run() { { scripts/launch-check.sh --json 2>/dev/null || true; } | sed -n 's/.*"run":"\([^"]*\)".*/\1/p'; }
detail_of() { sed -n 's/.*"detail":"\([^"]*\)".*/\1/p' <<<"$1"; }

# Swaps $1 into dist/ and reopens it (scripts/restart-app.sh does the quit, verified copy and open). Sets $restart_detail.
swap_in() {
  local out
  out=$(SRC_OVERRIDE="$1" scripts/restart-app.sh --json 2>/dev/null) && return 0
  restart_detail=$(detail_of "$out")
  return 1
}

# Waits up to 25 s for a launch newer than $1 and reports whether it passed. Sets $check_detail.
launch_ok() {
  local before="$1" run="" out=""
  for _ in $(seq 1 25); do
    sleep 1
    run=$(newest_run)
    [[ -n "$run" && "$run" != "$before" ]] || continue
    out=$(scripts/launch-check.sh --json 2>/dev/null) && return 0
  done
  check_detail="${out:-no new launch was logged}"
  return 1
}

if [[ $ROLLBACK -eq 1 ]]; then
  [[ -d dist/PairVox.previous.app ]] || finish false "There is no dist/PairVox.previous.app to go back to." 1
  if [[ $DRY -eq 1 ]]; then say "Would reopen dist/PairVox.previous.app in place of dist/PairVox.app"; finish true "dry run" 0; fi
  rm -rf .build/rollback && mkdir -p .build/rollback
  cp -R dist/PairVox.previous.app .build/rollback/PairVox.app   # the swap replaces dist/, so copy it out first
  restart_detail=""
  swap_in .build/rollback/PairVox.app || finish false "Reopening the previous build failed: ${restart_detail:-see scripts/restart-app.sh}" 1
  say "Rolled back to the previous build"
  finish true "rolled back" 0
fi

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ $PULL -eq 1 ]]; then
  git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 \
    || finish false "$branch has no upstream branch to update from, so nothing was changed. Push it, or run without --pull." 1
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || finish false "The checkout has uncommitted changes, so it was not updated. Commit or stash them, or run without --pull." 1
  if [[ $DRY -eq 1 ]]; then say "Would fast-forward $branch from $(git rev-parse --abbrev-ref '@{upstream}')"
  else
    git fetch --quiet || finish false "git fetch failed; nothing was changed." 1
    git merge --ff-only --quiet '@{upstream}' 2>/dev/null \
      || finish false "$branch and its upstream have both moved on, so it cannot be fast-forwarded; nothing was changed." 1
    say "Brought $branch up to date ($(git rev-parse --short HEAD))"
  fi
fi

if [[ $DRY -eq 1 ]]; then
  say "Would build $(git rev-parse --short HEAD) into .build/install, swap it into dist/PairVox.app, reopen it and check the launch; the app it replaces becomes dist/PairVox.previous.app once the new one passes, or comes back if it does not"
  finish true "dry run" 0
fi

# Build beside the installed app, never over it: DIST_DIR keeps build-app.sh away from dist/ while the app runs.
DIST_DIR=.build/install scripts/build-app.sh >/dev/null 2>&1 || finish false "The build failed; the installed app was not touched. Run scripts/build-app.sh to see why." 1
codesign --verify --deep --strict .build/install/PairVox.app 2>/dev/null || finish false "The new build's signature is broken; the installed app was not touched." 1
# A build with no signing team (no Apple Development certificate found) loses the hardened runtime and the Keychain and
# microphone grants keyed on the team: never let one replace a team-signed app (audit run 8).
team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
old_team=$([[ -d dist/PairVox.app ]] && team_of dist/PairVox.app || true)
new_team=$(team_of .build/install/PairVox.app)
if [[ -n "$old_team" && "$old_team" != "not set" && "$new_team" != "$old_team" ]]; then
  finish false "The new build is signed by team '${new_team:-none}', the installed app by '$old_team'. It was not installed; check the Apple Development certificate in Keychain Access." 1
fi
say "Built $(git rev-parse --short HEAD)"

had_app=0
if [[ -d dist/PairVox.app ]]; then
  had_app=1
  rm -rf .build/install/replaced.app
  cp -R dist/PairVox.app .build/install/replaced.app
fi

before=$(newest_run)
restart_detail="" check_detail=""
swap_in .build/install/PairVox.app || finish false "Swapping in the new build failed: ${restart_detail:-see scripts/restart-app.sh}. The installed app was not changed." 1
say "Installed and reopened"

if launch_ok "$before"; then
  say "Launch check passed"
  if [[ $had_app -eq 1 ]]; then
    rm -rf dist/PairVox.previous.app
    mv .build/install/replaced.app dist/PairVox.previous.app
    say "Kept the app it replaced as dist/PairVox.previous.app"
  fi
  finish true "installed" 0
fi

if [[ $had_app -eq 1 ]]; then
  restart_detail=""
  if swap_in .build/install/replaced.app; then
    say "The new build failed its launch check, so the app it replaced was put back"
    finish false "The new build did not pass the launch check ($check_detail), so the app it replaced is running again." 1
  fi
  finish false "The new build did not pass the launch check ($check_detail), and putting the old one back failed: ${restart_detail:-see scripts/restart-app.sh}. Its copy is .build/install/replaced.app." 1
fi
finish false "The new build did not pass the launch check: $check_detail" 1
