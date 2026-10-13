# Claude Code stream-json: what PairVox relies on

These notes were verified live against **Claude Code 2.1.296** (October 2026) and the type definitions in `@anthropic-ai/claude-agent-sdk` 0.3.296. The fixture `Tests/PairVoxCoreTests/Fixtures/claude-2.1.296-session.jsonl` is that live capture, sanitized.

## Launch

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio \
       --permission-mode default|plan|acceptEdits [--model M] [--append-system-prompt S] [--resume ID]
```

The process stays alive across turns until stdin closes. Launching it a few seconds before the first message removes most cold-start delay. In testing, an explicit `initialize` control request made no measurable difference.

## Input (stdin, one JSON object per line)

| Purpose | Line |
|---|---|
| User turn | `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null}` |
| Interrupt current turn | `{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}` |
| Answer a permission prompt | `{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"allow","updatedInput":{…}}}}` |
| …deny (optionally stop the turn) | `…"response":{"behavior":"deny","message":"…","interrupt":false}` |
| …allow and remember | add `"updatedPermissions": <the request's permission_suggestions>` |
| Change mode / model | `{"type":"control_request",…,"request":{"subtype":"set_permission_mode","mode":"plan"}}` / `set_model` |

A user message sent while a turn is running is queued until that turn ends. To redirect, send `interrupt` first; the next message then starts almost immediately.

## Output (stdout)

- `system/init`: `session_id`, `model`, `cwd`, `permissionMode`, `tools`, `claude_code_version`. **Re-sent at the start of every turn.**
- `system/status` (`requesting`), `system/thinking_tokens`.
- `stream_event`: raw Messages API stream events (`message_start`, `content_block_start/delta/stop`, `message_delta`, `message_stop`). Text arrives as `text_delta`. `parent_tool_use_id` is set for sub-agent traffic.
- `assistant`: the complete message, sent **in addition to** the deltas. Translate text only once. It carries `error` (`authentication_failed`, `rate_limit`, `billing_error`, …) when the API call failed.
- `user`: tool results (`tool_result` blocks), or `[Request interrupted by user]` after an interrupt.
- `control_request` `can_use_tool` asks permission for a tool call. Fields used:
  - `request_id`, `tool_name`, `display_name`, `input`, `description`, `tool_use_id`
  - `permission_suggestions`
  - `decision_reason`, `decision_reason_type`, `default_to_no`
  - `requires_user_interaction`, `suppress_always_allow_rule`
- `control_cancel_request`: the CLI no longer needs an answer. This happens, for example, when you interrupt while a permission prompt is open.
- `control_response`: the reply to our requests. `interrupt` returns `{"still_queued":[]}`, about 10 ms after sending.
- `rate_limit_event`: subscription utilization for the five-hour and seven-day windows (shown in the UI).
- `result` closes each turn:
  - `success`: carries the full text in `result`.
  - `error_during_execution`: after an interrupt. `result` is null, and `errors` holds `[ede_diagnostic] …` strings.

## Robustness rules in `ClaudeCLISession`

- Unknown message types are ignored (`.unknown`); new CLI versions don't break parsing.
- Control requests other than `can_use_tool` (hooks, elicitation, dialogs) get an immediate `control_response` error so the CLI never blocks waiting for a voice client.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are stripped in subscription mode, so an exported key can't silently override the user's login. Nested-session markers (`CLAUDECODE`, `CLAUDE_CODE_SESSION*`) are stripped as well.
- If the process exits, the next message relaunches it with `--resume <session_id>`.
