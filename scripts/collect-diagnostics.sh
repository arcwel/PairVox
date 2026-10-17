#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Zips PairVox's logs and a short system summary into one file you can send for QA, when the
# app's own Help > Export Diagnostics isn't available (it won't launch, or you are on the CLI).
# Logs are already scrubbed of API keys, tokens, e-mail addresses and your home folder at write
# time; this script scrubs the system summary the same way. Nothing is uploaded.
#
#   scripts/collect-diagnostics.sh            # writes ~/Desktop/PairVox-diagnostics-<time>.zip
#   scripts/collect-diagnostics.sh --dry-run  # lists what would be included
#   scripts/collect-diagnostics.sh --json     # prints {"zip": ..., "files": N} when done
set -uo pipefail

DRY=0; JSON=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

LOGDIR="$HOME/Library/Logs/PairVox"
CRASHDIR="$HOME/Library/Logs/DiagnosticReports"
[[ -d "$LOGDIR" ]] || { echo "No logs at $LOGDIR yet. Run PairVox first." >&2; exit 2; }

scrub() { sed -e "s#$HOME#~#g" -e "s#/Users/$USER#/Users/<user>#g" -e "s#$USER#<user>#g" \
  -E -e 's/sk-ant-[A-Za-z0-9_-]{8,}/<api-key>/g' -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'; }

FILES=("$LOGDIR"/pairvox*.log)
CRASHES=()
while IFS= read -r f; do CRASHES+=("$f"); done < <(ls -t "$CRASHDIR"/PairVox-*.ips 2>/dev/null | head -3)

if (( DRY )); then
  printf 'logs:\n'; printf '  %s\n' "${FILES[@]}"
  printf 'recent crash reports:\n'; printf '  %s\n' "${CRASHES[@]:-none}"
  exit 0
fi

STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
STAGE="$(mktemp -d)/PairVox-diagnostics-$STAMP"
mkdir -p "$STAGE/logs" "$STAGE/crash-reports"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

cp "${FILES[@]}" "$STAGE/logs/"
for c in "${CRASHES[@]:-}"; do [[ -n "$c" ]] && scrub < "$c" > "$STAGE/crash-reports/$(basename "$c")"; done
{
  echo "generated: $(date -u +%FT%TZ)"
  echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "model: $(sysctl -n hw.model)"
  echo "chip: $(sysctl -n machdep.cpu.brand_string)"
  echo "memory_gb: $(( $(sysctl -n hw.memsize) / 1073741824 ))"
  echo "claude: $(command -v claude >/dev/null && claude --version 2>/dev/null || echo 'not found')"
  echo; echo "audio devices:"; system_profiler SPAudioDataType 2>/dev/null | sed -n '1,60p'
} | scrub > "$STAGE/system.txt"

ZIP="$HOME/Desktop/PairVox-diagnostics-$STAMP.zip"
ditto -c -k --keepParent "$STAGE" "$ZIP" || { echo "zip failed" >&2; exit 1; }
N=$(find "$STAGE" -type f | wc -l | tr -d ' ')
if (( JSON )); then printf '{"zip":"%s","files":%s}\n' "$ZIP" "$N"; else echo "Wrote $ZIP ($N files). Nothing was uploaded."; fi
