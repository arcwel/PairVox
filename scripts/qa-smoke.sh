#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Non-audio QA from docs/HANDOFF.md §6 P1, run through pairvox-cli against your real `claude`
# login in a throwaway git repo. It makes real model calls (4 short Haiku turns), so it only
# runs when you ask for it.
#
#   scripts/qa-smoke.sh --dry-run    # print the plan and call count, spawn nothing
#   scripts/qa-smoke.sh              # run it
#   scripts/qa-smoke.sh --json       # run it, print one JSON result line per check
#
#   scripts/qa-smoke.sh --only approve   # run one check (answer, approve, high-risk, brainstorm)
#
# Exit code: 0 all checks passed, 1 a check failed, 2 setup problem.
set -uo pipefail
cd "$(dirname "$0")/.."

DRY=0; JSON=0; ONLY=""
while (( $# )); do
  a="$1"; shift
  case "$a" in
    --only) ONLY="${1:-}"; shift ;;
    --dry-run) DRY=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

CHECKS=(
  "answer|Ask a question; expect a spoken reply and a first-audio time"
  "approve|Ask for a new file; expect a permission prompt, then a spoken yes creates it"
  "high-risk|Ask for launchctl (high risk, read-only); expect a spoken yes to be refused"
  "brainstorm|In brainstorm mode ask for an edit; expect the file to stay unchanged"
)
if (( DRY )); then
  echo "qa-smoke plan (4 real Haiku turns, scratch repo in a temp dir, nothing outside it is touched):"
  for c in "${CHECKS[@]}"; do echo "  ${c%%|*}: ${c#*|}"; done
  exit 0
fi

command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 2; }
CLI=".build/debug/pairvox-cli"
if [[ ! -x "$CLI" ]]; then
  swift build --build-system native --product pairvox-cli >/dev/null 2>&1 || { echo "build failed" >&2; exit 2; }
fi

WORK="$(mktemp -d)"; trap 'kill "$CLIPID" 2>/dev/null; rm -rf "$WORK"' EXIT
CLIPID=""
FAILED=0
report() { # name status detail
  if (( JSON )); then printf '{"check":"%s","status":"%s","detail":"%s"}\n' "$1" "$2" "$3"
  else printf '  %-11s %s  %s\n' "$1" "$2" "$3"; fi
  [[ "$2" == "pass" ]] || FAILED=1
}

fresh_repo() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
  ( cd "$WORK/repo" && git init -q && printf 'def add(a, b):\n    return a + b\n' > calc.py \
    && git add -A && git -c user.name=qa -c user.email=qa@example.com commit -qm init )
}

# Starts the CLI reading from a FIFO and writing to a log. $@ = extra CLI flags.
start() {
  rm -f "$WORK/in" "$WORK/log"; mkfifo "$WORK/in"; : > "$WORK/log"
  "$CLI" --cwd "$WORK/repo" --model haiku --no-ack --metrics "$@" < "$WORK/in" > "$WORK/log" 2>&1 &
  CLIPID=$!
  exec 3> "$WORK/in"
  await "Ready\." 60 || { echo "CLI did not start: $(tail -3 "$WORK/log")" >&2; exit 2; }
}
send() { printf '%s\n' "$1" >&3; }
await() { # pattern timeout_seconds
  local end=$((SECONDS + $2))
  while (( SECONDS < end )); do grep -Eq "$1" "$WORK/log" && return 0; sleep 0.5; done
  return 1
}
stop() { send "/quit"; exec 3>&-; wait "$CLIPID" 2>/dev/null; CLIPID=""; }

want() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
dump() { echo "---- last lines of the CLI log ----" >&2; tail -25 "$WORK/log" >&2; }
echo "qa-smoke: ${ONLY:+1 check, }Haiku turns in $WORK/repo"

want answer && {
fresh_repo; start
send "What does this project do, in one sentence?"
if await "first audio" 90; then report answer pass "$(grep -o 'first audio [0-9.]*s' "$WORK/log" | head -1)"
else report answer fail "no spoken reply within 90 s"; fi
stop
}

want approve && {
fresh_repo; start
send "Create a file named hello.txt containing the word hi."
if await "Permission:" 90; then
  # Claude sometimes asks twice (a harmless look first, then the write), so answer each prompt in turn.
  for answered in 1 2 3 4; do
    send "yes"
    sleep 6
    [[ -f "$WORK/repo/hello.txt" ]] && break
    (( $(grep -c "Permission:" "$WORK/log") > answered )) || break
  done
  if [[ -f "$WORK/repo/hello.txt" ]]; then report approve pass "prompt appeared, yes created hello.txt"
  else report approve fail "prompt appeared but hello.txt was not created"; dump; fi
else report approve fail "no permission prompt within 90 s"; fi
stop
}

want high-risk && {
# `launchctl` is high risk in PairVox's policy even when read-only, so asking for it exercises the click-only rule with
# nothing at stake. (rm -rf and git push are high risk too, but many people deny the first in their own Claude Code
# settings and have global rules that make Claude ask about the second, so those never reach PairVox.)
fresh_repo
start
send "Run launchctl list and tell me how many services it shows."
# Claude may look around first; answer those harmless prompts until the push itself is asked.
seen=0
for _ in 1 2 3 4; do
  await "risk: high|Permission:" 90 >/dev/null || break
  grep -q "risk: high" "$WORK/log" && break
  (( $(grep -c "Permission:" "$WORK/log") > seen )) && { seen=$((seen + 1)); send "yes"; sleep 5; }
done
if grep -q "risk: high" "$WORK/log"; then
  send "yes"
  await "needs a click" 15 >/dev/null
  if grep -q "needs a click" "$WORK/log"; then
    report high-risk pass "spoken yes refused, the click-only rule held"
  else report high-risk fail "spoken yes was not refused"; dump; fi
else report high-risk fail "no high-risk prompt within 90 s (is the command classified high?)"; dump; fi
stop
}

want brainstorm && {
fresh_repo; start --brainstorm
before="$(shasum "$WORK/repo/calc.py")"
send "Change add so it also accepts a third argument c."
await "first audio" 90 >/dev/null; sleep 2
if [[ "$(shasum "$WORK/repo/calc.py")" == "$before" ]]; then report brainstorm pass "calc.py unchanged in plan mode"
else report brainstorm fail "calc.py was modified in brainstorm mode"; fi
stop
}

exit "$FAILED"
