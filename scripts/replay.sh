#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the voice replay scenarios (synthetic speech through the real detector and engine, with a simulated
# leaking speaker) and prints their measurements, without the rest of the test suite.
#
#   scripts/replay.sh                 # every replay scenario
#   scripts/replay.sh Echo            # scenarios whose test name contains "Echo"
#   scripts/replay.sh EarlyTranscription
#
# Needs macOS (speech comes from `say`); no models, no network. Exit 0 all passed, 1 a scenario failed.
set -euo pipefail
cd "$(dirname "$0")/.."

FILTER="${1:-}"
PATTERN="ReplayTests"
[[ -n "$FILTER" ]] && PATTERN="ReplayTests.*$FILTER|${FILTER}.*ReplayTests"

LOG="$(mktemp -t pairvox-replay)"
trap 'rm -f "$LOG"' EXIT
swift test --build-system native --filter "$PATTERN" 2>&1 | tee "$LOG" | grep -E "^(ECHO|BURST|CLEAN|OVER|EARLY|agent clip)|error:|failed \(" || true
grep -qE "with 0 failures" "$LOG"
