#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the voice replay scenarios (synthetic speech through the real detector and engine, with a simulated
# leaking speaker) and prints their measurements, without the rest of the test suite.
#
#   scripts/replay.sh                       # the replay tests
#   scripts/replay.sh --explore             # also the sweeps that print ECHO/BURST/CLEAN/OVER/RISE/USER/QUIET lines
#   scripts/replay.sh OurOwnVoice           # only tests whose name matches this regular expression
#   scripts/replay.sh --explore Sweep
#
# Needs macOS (speech comes from `say`); no models, no network.
# Exit codes: 0 all passed (and at least one ran), 1 a test failed or nothing ran, 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPLORE=0
FILTER=""
for arg in "$@"; do
  case "$arg" in
    --explore) EXPLORE=1 ;;
    -*) echo "usage: scripts/replay.sh [--explore] [TEST-NAME-REGEX]" >&2; exit 2 ;;
    *) [[ -z "$FILTER" ]] || { echo "usage: scripts/replay.sh [--explore] [TEST-NAME-REGEX]" >&2; exit 2; }; FILTER="$arg" ;;
  esac
done
# Every replay class has "Replay" in its name; the filter is a regular expression over the test's full name.
PATTERN="Replay"
[[ -n "$FILTER" ]] && PATTERN="Replay.*(${FILTER})"
[[ $EXPLORE -eq 1 ]] && export PAIRVOX_REPLAY_EXPLORE=1

LOG="$(mktemp -t pairvox-replay)"
trap 'rm -f "$LOG"' EXIT
set +e
swift test --build-system native --filter "$PATTERN" 2>&1 | tee "$LOG" \
  | grep -E "^(ECHO|BURST|CLEAN|OVER|RISE|USER|QUIET|EARLY|agent clip)|error:|failed \("
RC=${PIPESTATUS[0]}
set -e

TOTAL="$(grep -E '^[[:space:]]*Executed [0-9]+ tests?,' "$LOG" | tail -1 || true)"
RAN="$(sed -nE 's/^[[:space:]]*Executed ([0-9]+) tests?,.*/\1/p' <<<"$TOTAL")"
FAILED="$(sed -nE 's/.* ([0-9]+) failures?.*/\1/p' <<<"$TOTAL")"
if [[ $RC -ne 0 || -z "$RAN" || "$RAN" -eq 0 || -z "$FAILED" || "$FAILED" -ne 0 ]]; then
  echo "replay FAILED: swift test exit $RC, ${TOTAL:-no test total printed}" >&2
  exit 1
fi
