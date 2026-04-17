#!/usr/bin/env bash
# PostToolUse hook — reply 工具成功执行后，创建 .replied 标记，防止 Stop hook 误报。
#
# 输入 (stdin JSON):
#   { session_id, tool_name, tool_input, tool_response, ... }

set -euo pipefail

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"

payload=$(cat || true)
[[ -z "$payload" ]] && exit 0

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null || echo "")
session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || echo "")
is_error=$(jq -r '.tool_response.isError // false' <<<"$payload" 2>/dev/null || echo "false")

# 只对 wechat-channel 的 reply 工具感兴趣
[[ "$tool_name" != "mcp__wechat-channel__reply" ]] && exit 0
[[ -z "$session_id" ]] && exit 0
[[ "$is_error" == "true" ]] && exit 0

touch "$HOOKS_DIR/${session_id}.replied"
exit 0
