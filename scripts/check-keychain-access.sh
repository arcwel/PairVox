#!/bin/bash
# Which programs can read PairVox's saved API key without a Keychain prompt? Reads the item's access list
# (never the key itself). --probe also creates a dummy item the same way the app does and tries to read it from a
# second process; macOS may flash a Keychain prompt for up to 10 seconds, which is the protection working.
#   scripts/check-keychain-access.sh [--json] [--probe]      exit 1 if the item is readable without a prompt
set -euo pipefail
cd "$(dirname "$0")/keychain-check"
BIN="$(mktemp -d)/pv-keychain-check"
swiftc -O -suppress-warnings main.swift -o "$BIN"
"$BIN" "$@"
