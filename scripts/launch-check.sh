#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks that the newest PairVox launch came up without waiting on anything: the shortcuts registered within a
# few seconds (a launch that waits in a permission dialog registers them only once someone clicks) and the audio
# engine started. Reads ~/Library/Logs/PairVox/pairvox.log.
#
#   scripts/launch-check.sh                 # newest run
#   scripts/launch-check.sh RUNID           # a specific run
#   scripts/launch-check.sh --json          # one JSON object on stdout
#   scripts/launch-check.sh --max-seconds 5 # limit for the shortcuts (default 5)
# Exit codes: 0 launch ok, 1 launch waited or no engine, 2 bad usage, 3 no log or run.
set -euo pipefail

LOG="${PAIRVOX_LOG:-$HOME/Library/Logs/PairVox/pairvox.log}"
RUN="" JSON=0 MAX=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1 ;;
    --max-seconds) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: --max-seconds N" >&2; exit 2; }; MAX="$2"; shift ;;
    --log) [[ $# -ge 2 ]] || { echo "usage: --log FILE" >&2; exit 2; }; LOG="$2"; shift ;;
    -h|--help) sed -n '4,13p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$RUN" ]] || { echo "one run id only" >&2; exit 2; }; RUN="$1" ;;
  esac
  shift
done
[[ -z "$RUN" || "$RUN" =~ ^[a-f0-9]+$ ]] || { echo "a run id is hex, like 16e4c87a" >&2; exit 2; }
[[ -r "$LOG" ]] || { echo "no log at $LOG" >&2; exit 3; }
if [[ -z "$RUN" ]]; then
  RUN=$(grep -o '"run":"[a-f0-9]*"' "$LOG" | tail -1 | cut -d'"' -f4 || true)
  [[ -n "$RUN" ]] || { echo "no run in $LOG" >&2; exit 3; }
fi

lines=$(grep "\"run\":\"$RUN\"" "$LOG" || true)
[[ -n "$lines" ]] || { echo "no lines for run $RUN" >&2; exit 3; }
ms_of() { grep -m1 "$1" <<<"$lines" | grep -o '"ms":[0-9]*' | cut -d: -f2 || true; }
hotkeys_ms=$(ms_of '"ev":"register"')
engine_ms=$(ms_of '"ev":"engine.started')
engine_fail=$(grep -m1 '"ev":"engine.start.failed"' <<<"$lines" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || true)
launch_t=$(grep -m1 '"ev":"app.launch"' <<<"$lines" | grep -o '"t":"[^"]*"' | cut -d'"' -f4 || true)

ok=true; problems=()
if [[ -z "$hotkeys_ms" ]]; then
  ok=false; problems+=("shortcuts never registered: the launch is still waiting (a permission dialog?)")
elif (( hotkeys_ms > MAX * 1000 )); then
  ok=false; problems+=("shortcuts registered after $((hotkeys_ms / 1000)) s (limit ${MAX} s): the launch waited on something, usually a permission dialog")
fi
if [[ -z "$engine_ms" ]]; then
  ok=false
  if [[ -n "$engine_fail" ]]; then problems+=("audio engine failed to start: $engine_fail"); else problems+=("audio engine never started"); fi
fi

if [[ $JSON -eq 1 ]]; then
  printf '{"run":"%s","launchedAt":"%s","ok":%s,"hotkeysMs":%s,"engineMs":%s,"problems":[' "$RUN" "$launch_t" "$ok" "${hotkeys_ms:-null}" "${engine_ms:-null}"
  for i in "${!problems[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '"%s"' "${problems[$i]//\"/\\\"}"; done
  printf ']}\n'
else
  echo "run $RUN (launched $launch_t)"
  [[ -n "$hotkeys_ms" ]] && echo "  shortcuts registered at ${hotkeys_ms} ms" || echo "  shortcuts: not registered"
  [[ -n "$engine_ms" ]] && echo "  audio engine started at ${engine_ms} ms" || echo "  audio engine: not started"
  for p in "${problems[@]+"${problems[@]}"}"; do echo "  PROBLEM: $p"; done
  $ok && echo "launch ok"
fi
$ok && exit 0 || exit 1
