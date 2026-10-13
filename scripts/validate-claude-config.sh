#!/bin/bash
# Checks, inside a macOS sandbox with no network, whether the `claude` CLI runs a repository's own
# hooks and MCP servers and honours its allow rules, for the argument sets PairVox can launch it with.
# Dummy HOME and repo only; nothing real is read, no API call is made.
#   scripts/validate-claude-config.sh [--json] [CLAUDE_BINARY]
set -u
JSON=0; [ "${1:-}" = "--json" ] && { JSON=1; shift; }
CLAUDE="${1:-$(command -v claude)}"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pv-claude-config.XXXXXX")" && pwd -P)"  # the sandbox matches resolved paths
[ "${KEEP:-0}" = 1 ] || trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
[ -x "$CLAUDE" ] || { echo "claude binary not found" >&2; exit 2; }

PROFILE="$WORK/sandbox.sb"
cat > "$PROFILE" <<SB
(version 1)
(allow default)
(deny network*)
(deny file-write* (require-not (require-any (subpath "$WORK") (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper"))))
(deny file-read* (subpath "$HOME/.ssh") (subpath "$HOME/.aws") (subpath "$HOME/.gnupg") (subpath "$HOME/Library/Keychains"))
SB

make_repo() {  # $1 = dir
  mkdir -p "$1/.claude"
  cat > "$1/.claude/settings.json" <<JS
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "touch $1/MARK_session_start_hook"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "touch $1/MARK_prompt_hook"}]}]
  },
  "permissions": {"allow": ["Bash(touch *)"]},
  "enableAllProjectMcpServers": true
}
JS
  cat > "$1/.mcp.json" <<JS
{"mcpServers": {"pvprobe": {"command": "/usr/bin/touch", "args": ["$1/MARK_mcp_server"]}}}
JS
}

run_case() {  # $1 = name, rest = extra args
  local name="$1"; shift
  local repo="$WORK/repo-$name" home="$WORK/home-$name"
  mkdir -p "$home" "$WORK/tmp-$name"; make_repo "$repo"
  # The user's own MCP server, which must keep loading whatever is done about the repository's.
  cat > "$home/.claude.json" <<JS
{"mcpServers": {"pvuser": {"command": "/usr/bin/touch", "args": ["$repo/MARK_user_mcp_server"]}}}
JS
  local msg='{"type":"user","message":{"role":"user","content":"hello"},"parent_tool_use_id":null}'
  ( cd "$repo" && printf '%s\n' "$msg" | env -i HOME="$home" TMPDIR="$WORK/tmp-$name" PATH="/usr/bin:/bin:$(dirname "$CLAUDE")" \
      sandbox-exec -f "$PROFILE" /usr/bin/perl -e 'alarm 45; exec @ARGV' "$CLAUDE" -p --input-format stream-json --output-format stream-json --verbose \
      --permission-prompt-tool stdio --permission-mode default "$@" > "$WORK/out-$name.txt" 2> "$WORK/err-$name.txt" )
  local s=no p=no m=no u=no
  [ -e "$repo/MARK_session_start_hook" ] && s=yes
  [ -e "$repo/MARK_prompt_hook" ] && p=yes
  [ -e "$repo/MARK_mcp_server" ] && m=yes
  [ -e "$repo/MARK_user_mcp_server" ] && u=yes
  local ignored; ignored="$(grep -c 'has not been trusted' "$WORK/err-$name.txt")"
  echo "$name | project hook ran: $s | project MCP launched: $m | user MCP launched: $u | project allow rule ignored (untrusted): $([ "$ignored" -gt 0 ] && echo yes || echo no)"
}

run_case default
run_case user_only --setting-sources user
run_case user_strict --setting-sources user --strict-mcp-config
