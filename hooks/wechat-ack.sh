#!/usr/bin/env bash
# UserPromptSubmit hook — 即时回复 "收到，处理中..."，持久化会话状态供 Stop hook 使用。
#
# 输入（stdin JSON，由 Claude Code 注入）:
#   { session_id, transcript_path, cwd, prompt, hook_event_name }
# 依赖: jq, curl
# 状态目录: ${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}

set -euo pipefail

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"

LOG_FILE="$HOOKS_DIR/ack.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

payload=$(cat || true)
[[ -z "$payload" ]] && exit 0

session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || echo "")
prompt=$(jq -r '.prompt // ""' <<<"$payload" 2>/dev/null || echo "")

# 只处理来自 wechat-channel 的消息
channel_tag=$(grep -oE '<channel source="wechat-channel"[^>]*>' <<<"$prompt" | head -1 || true)
[[ -z "$channel_tag" ]] && exit 0

extract_attr() { grep -oE "$1=\"[^\"]+\"" <<<"$channel_tag" | head -1 | sed -E "s/.*=\"([^\"]+)\"/\\1/"; }
user_id=$(extract_attr 'user_id')
context_token=$(extract_attr 'context_token')
message_id=$(extract_attr 'message_id')

[[ -z "$user_id" || -z "$context_token" ]] && exit 0

# 提取 channel 标签内的正文
body=$(python3 -c '
import re, sys
m = re.search(r"<channel source=\"wechat-channel\"[^>]*>([\s\S]*?)</channel>", sys.argv[1])
print(m.group(1).strip() if m else "")
' "$prompt" 2>/dev/null || echo "")

profile="${WECHAT_PROFILE:-default}"
account_file="$HOME/.claude/channels/wechat/$profile/account.json"
if [[ ! -f "$account_file" ]]; then
  log "no account file at $account_file (profile=$profile)"
  exit 0
fi
token=$(jq -r '.token // ""' "$account_file")
base_url=$(jq -r '.baseUrl // "https://ilinkai.weixin.qq.com"' "$account_file")
[[ -z "$token" ]] && exit 0

send_wechat_msg() {
  local text="$1" req
  req=$(jq -n \
    --arg to "$user_id" --arg ctx "$context_token" --arg txt "$text" \
    '{msg: {to_user_id: $to, message_type: 2, message_state: 2,
            item_list: [{type: 1, text_item: {text: $txt}}],
            context_token: $ctx},
      base_info: {channel_version: "0.1.0"}}')
  curl -s --max-time 5 -X POST "${base_url%/}/ilink/bot/sendmessage" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -H "AuthorizationType: ilink_bot_token" \
    -d "$req" >/dev/null 2>&1 || true
}

ack_text="收到，处理中..."
hook_decision=""
additional_ctx=""

case "$body" in
  /new|/new\ *)
    ack_text="✅ 已开始新话题。"
    additional_ctx="# System
The user sent '/new'. Ignore any previous conversation context and treat this as a fresh topic. Acknowledge briefly."
    ;;
  /help|/help\ *)
    ack_text=$'可用命令：\n/new    开始新话题\n/help   显示帮助\n/status 查看运行状态\n其他消息会转给 Claude Code 处理。'
    hook_decision="block"
    ;;
  /status|/status\ *)
    ack_text="Claude Code 运行中 — session: ${session_id:0:8}, profile: ${profile}"
    hook_decision="block"
    ;;
esac

send_wechat_msg "$ack_text"
log "ack sent session=$session_id user=$user_id msg_id=$message_id body_head=${body:0:40}"

# 持久化会话状态（供 Stop hook 判断"是否已回复"）
state_file="$HOOKS_DIR/${session_id}.session.json"
jq -n \
  --arg uid "$user_id" \
  --arg ctx "$context_token" \
  --arg mid "$message_id" \
  --arg profile "$profile" \
  '{user_id:$uid, context_token:$ctx, message_id:$mid, profile:$profile}' \
  > "$state_file"

# 返回 hook 响应
if [[ "$hook_decision" == "block" ]]; then
  jq -n --arg r "slash command handled by wechat-ack hook" \
    '{decision:"block", reason:$r}'
elif [[ -n "$additional_ctx" ]]; then
  jq -n --arg c "$additional_ctx" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
fi
exit 0
