# SPDX-License-Identifier: Apache-2.0
#
# Helpers shared by the scripts in scripts/. Source it with: source "$(dirname "$0")/lib/common.sh"

# A string made safe to put between quotes in JSON: backslashes and quotes escaped, control characters dropped.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

# True when the signed app at $1 runs with the hardened runtime. The output is captured first: with pipefail,
# grep -q closing the pipe early can make the pipeline report failure.
has_hardened_runtime() {
  local signature
  signature="$(codesign -dv "$1" 2>&1 || true)"
  [[ "$signature" == *"flags="*"runtime"* ]]
}
