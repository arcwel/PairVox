#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the soak tests for longer than the default 8 s and prints their measurements.
#
#   scripts/soak.sh            # 60 s of engine soak, plus the link soak and fault tests
#   scripts/soak.sh 600        # ten minutes
#   scripts/soak.sh 60 --json  # one JSON object per measurement line
#
# Exit codes: 0 all soak tests passed, 1 a test failed, 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_TO_RUN="${1:-60}"
JSON=0
[[ "${2:-}" == "--json" ]] && JSON=1
[[ "$SECONDS_TO_RUN" =~ ^[0-9]+$ ]] || { echo "usage: scripts/soak.sh [SECONDS] [--json]" >&2; exit 2; }

LOG="$(mktemp -t pairvox-soak)"
trap 'rm -f "$LOG"' EXIT

echo "soak: engine ${SECONDS_TO_RUN}s, link soak and fault tests (log: $LOG)" >&2
STATUS=0
PAIRVOX_SOAK_SECONDS="$SECONDS_TO_RUN" swift test --build-system native \
  --filter "EngineSoakTests|LinkSoakTests" 2>&1 | tee "$LOG" | grep -E "^SOAK|^FAULT|error:|failed \(" >&2 || true
grep -qE "with 0 failures" "$LOG" || STATUS=1

if [[ $JSON -eq 1 ]]; then
  grep -E "^SOAK|^FAULT" "$LOG" | python3 -c '
import json, sys
for line in sys.stdin:
    name, _, rest = line.strip().partition(":")
    print(json.dumps({"test": name.strip(), "summary": rest.strip()}))'
else
  grep -E "^SOAK|^FAULT" "$LOG" || echo "no SOAK lines: the tests did not run" >&2
fi
exit $STATUS
