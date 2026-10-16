#!/bin/bash
# Every 5 s: is the process alive, when was the log last written, and is it answering its control socket.
L=~/Library/Logs/PairVox/pairvox.log; OUT="$1"; CLI="/Users/anthonyguidry/HD Projects/PairVox/.build/arm64-apple-macosx/debug/pairvox-link"
while true; do
  pid=$(pgrep -f "dist/PairVox.app/Contents/MacOS/PairVox$" | head -1)
  last=$(tail -1 "$L" | grep -o '"t":"[^"]*"' | cut -d'"' -f4)
  st=$(timeout 5 "$CLI" status --json 2>/dev/null | grep -o '"ok" : [a-z]*' || echo "noReply")
  echo "$(date -u +%H:%M:%S) pid=${pid:-none} lastLog=$last control=$st" >> "$OUT"
  if [[ -n "$pid" && "$st" == "noReply" ]]; then sample "$pid" 2 -file "$OUT.sample-$(date +%H%M%S).txt" >/dev/null 2>&1; fi
  sleep 5
done
