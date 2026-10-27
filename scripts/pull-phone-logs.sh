#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Copies the iPhone app's logs to this Mac: its own log (Library/Logs/PairVox, with any crash reports iOS handed it)
# and the iPhone's system crash reports for PairVoxPhone. Works for a phone paired with this Mac (cable or Wi-Fi,
# a development build) or a simulator. Nothing is uploaded.
#
#   scripts/pull-phone-logs.sh                    # the only paired iPhone, into ~/Desktop/PairVoxPhone-logs-<time>/
#   scripts/pull-phone-logs.sh --device NAME|ID   # a given iPhone or simulator (name or identifier)
#   scripts/pull-phone-logs.sh --out DIR          # somewhere else
#   scripts/pull-phone-logs.sh --dry-run          # say which device and what would be copied
#   scripts/pull-phone-logs.sh --json             # one JSON object at the end
# Exit codes: 0 copied, 1 nothing could be copied, 2 bad usage or no device found.
set -uo pipefail

BUNDLE="app.pairvox.PairVoxPhone"
DEVICE="" OUT="" DRY=0 JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --json) JSON=1; shift ;;
    *) echo "usage: scripts/pull-phone-logs.sh [--device NAME|ID] [--out DIR] [--dry-run] [--json]" >&2; exit 2 ;;
  esac
done
say() { (( JSON )) && echo "$@" >&2 || echo "$@"; }

# A simulator first if one was named or is the only thing booted with the app; otherwise a physical iPhone.
SIM=""
if [[ -n "$DEVICE" ]]; then
  SIM="$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); want=sys.argv[1]
for devs in d['devices'].values():
    for x in devs:
        if want in (x['udid'], x['name']) and x['state']=='Booted': print(x['udid']); raise SystemExit" "$DEVICE")"
fi
PHONE=""
if [[ -z "$SIM" ]]; then
  LIST="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null)"
  PHONE="$(python3 -c "
import json,sys; want=sys.argv[1]
d=json.loads(sys.stdin.read() or '{}')
devs=[x for x in d.get('result',{}).get('devices',[]) if x.get('hardwareProperties',{}).get('platform')=='iOS'
      and x.get('hardwareProperties',{}).get('reality')=='physical']
if want: devs=[x for x in devs if want in (x.get('identifier'), x.get('deviceProperties',{}).get('name'), x.get('hardwareProperties',{}).get('udid'))]
if len(devs)==1: print(devs[0]['hardwareProperties']['udid'])" "$DEVICE" <<<"$LIST")"
fi
if [[ -z "$SIM" && -z "$PHONE" ]]; then
  echo "No single iPhone found. Connect it (or pass --device NAME), unlock it, and trust this Mac." >&2; exit 2
fi
TARGET="${SIM:-$PHONE}"
OUT="${OUT:-$HOME/Desktop/PairVoxPhone-logs-$(date +%Y-%m-%dT%H-%M-%S)}"

if (( DRY )); then
  say "device: $TARGET ($([[ -n "$SIM" ]] && echo simulator || echo iPhone))"
  say "would copy: the app's Library/Logs/PairVox, and system crash reports named PairVoxPhone-*"
  say "into: $OUT"
  (( JSON )) && printf '{"ok":true,"dryRun":true,"device":"%s","out":"%s"}\n' "$TARGET" "$OUT"
  exit 0
fi

mkdir -p "$OUT/app-log" "$OUT/crash-reports"
if [[ -n "$SIM" ]]; then
  DATA="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data 2>/dev/null)"
  [[ -n "$DATA" && -d "$DATA/Library/Logs/PairVox" ]] && cp -R "$DATA/Library/Logs/PairVox/." "$OUT/app-log/"
  # Simulator crashes are reported on the Mac.
  cp ~/Library/Logs/DiagnosticReports/PairVoxPhone-*.ips "$OUT/crash-reports/" 2>/dev/null
else
  xcrun devicectl device copy from --device "$PHONE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Library/Logs/PairVox --destination "$OUT/app-log" >/dev/null 2>&1 \
    || say "Could not read the app's log folder (is the app installed, and has it run since the update?)."
  while read -r f; do
    [[ -n "$f" ]] && xcrun devicectl device copy from --device "$PHONE" --domain-type systemCrashLogs \
      --source "$f" --destination "$OUT/crash-reports/$(basename "$f")" >/dev/null 2>&1
  done < <(xcrun devicectl device info files --device "$PHONE" --domain-type systemCrashLogs 2>/dev/null \
             | awk '{print $1}' | grep -E '(^|/)PairVoxPhone[-_].*\.ips$')
fi

N=$(find "$OUT" -type f | wc -l | tr -d ' ')
if (( N == 0 )); then say "Nothing to copy yet: run the updated phone app first."; (( JSON )) && printf '{"ok":false,"out":"%s","files":0}\n' "$OUT"; exit 1; fi
say "Copied $N files to $OUT. Nothing was uploaded."
(( JSON )) && printf '{"ok":true,"device":"%s","out":"%s","files":%s}\n' "$TARGET" "$OUT" "$N"
exit 0
