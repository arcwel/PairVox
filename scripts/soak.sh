#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the soak tests for longer than the default 8 s and prints their measurements.
#
#   scripts/soak.sh            # 60 s of engine soak, plus the link soak and fault tests
#   scripts/soak.sh 600        # ten minutes
#   scripts/soak.sh 60 --json  # one JSON object per measurement line
#
# Exit codes: 0 all soak tests passed (and at least one ran), 1 a test failed or nothing ran, 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_TO_RUN="${1:-60}"
JSON=0
if [[ "${2:-}" == "--json" ]]; then JSON=1
elif [[ -n "${2:-}" ]]; then echo "usage: scripts/soak.sh [SECONDS] [--json]" >&2; exit 2; fi
[[ $# -le 2 && "$SECONDS_TO_RUN" =~ ^[0-9]+$ ]] || { echo "usage: scripts/soak.sh [SECONDS] [--json]" >&2; exit 2; }

LOG="$(mktemp -t pairvox-soak)"
trap 'rm -f "$LOG"' EXIT

echo "soak: engine ${SECONDS_TO_RUN}s, link soak and fault tests (log: $LOG)" >&2
set +e
PAIRVOX_SOAK_SECONDS="$SECONDS_TO_RUN" swift test --build-system native \
  --filter "EngineSoakTests|LinkSoakTests" 2>&1 | tee "$LOG" | grep -E "^SOAK|^FAULT|error:|failed \(" >&2
RC=${PIPESTATUS[0]}
set -e

# swift test's own exit status, and the final "Executed N tests, with M failures" line (the earlier ones are per
# suite, so a later failure would not show in them): tests must have run, and none may have failed.
TOTAL="$(grep -E '^[[:space:]]*Executed [0-9]+ tests?,' "$LOG" | tail -1 || true)"
RAN="$(sed -nE 's/^[[:space:]]*Executed ([0-9]+) tests?,.*/\1/p' <<<"$TOTAL")"
FAILED="$(sed -nE 's/.* ([0-9]+) failures?.*/\1/p' <<<"$TOTAL")"
STATUS=0
if [[ $RC -ne 0 || -z "$RAN" || "$RAN" -eq 0 || -z "$FAILED" || "$FAILED" -ne 0 ]]; then
  STATUS=1
  echo "soak FAILED: swift test exit $RC, ${TOTAL:-no test total printed}" >&2
fi

if [[ $JSON -eq 1 ]]; then
  grep -E "^SOAK|^FAULT" "$LOG" | python3 -c '
import json, sys
for line in sys.stdin:
    name, _, rest = line.strip().partition(":")
    print(json.dumps({"test": name.strip(), "summary": rest.strip()}))' || true
else
  grep -E "^SOAK|^FAULT" "$LOG" || echo "no SOAK lines: the tests did not run" >&2
fi
exit $STATUS
