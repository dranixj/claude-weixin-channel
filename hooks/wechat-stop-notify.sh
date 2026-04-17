#!/usr/bin/env bash
# Stop hook — Claude Code 停止响应时，若未调用 reply 工具，则向微信推送"异常停止"通知。
#
# 输入 (stdin JSON):
#   { session_id, stop_reason?, hook_event_name, ... }
# 依赖 wechat-ack.sh 写入的 ${session_id}.session.json 以及 wechat-reply-sent.sh 写入的 .replied 标记。

set -euo pipefail

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"
LOG_FILE="$HOOKS_DIR/stop.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

payload=$(cat || true)
[[ -z "$payload" ]] && exit 0

session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || echo "")
stop_reason=$(jq -r '.stop_reason // .reason // ""' <<<"$payload" 2>/dev/null || echo "")
[[ -z "$session_id" ]] && exit 0

session_file="$HOOKS_DIR/${session_id}.session.json"
replied_marker="$HOOKS_DIR/${session_id}.replied"

# 已成功回复过 → 清理，不通知
if [[ -f "$replied_marker" ]]; then
  rm -f "$session_file" "$replied_marker"
  exit 0
fi

# 本 session 不是 wechat 来源 → 跳过
[[ ! -f "$session_file" ]] && exit 0

user_id=$(jq -r '.user_id // ""' "$session_file")
context_token=$(jq -r '.context_token // ""' "$session_file")
profile=$(jq -r '.profile // "default"' "$session_file")

case "$stop_reason" in
  max_tokens)
    msg="⚠️ 回复因长度限制被截断，请稍后重试或缩小问题范围。"
    ;;
  *)
    msg="⚠️ 处理中断（原因：${stop_reason:-未知}），可能是用量已达上限。请稍后再试。"
    ;;
esac

account_file="$HOME/.claude/channels/wechat/$profile/account.json"
if [[ ! -f "$account_file" ]]; then
  log "no account file; skip notify"
  rm -f "$session_file"
  exit 0
fi
token=$(jq -r '.token // ""' "$account_file")
base_url=$(jq -r '.baseUrl // "https://ilinkai.weixin.qq.com"' "$account_file")

req=$(jq -n \
  --arg to "$user_id" --arg ctx "$context_token" --arg txt "$msg" \
  '{msg: {to_user_id: $to, message_type: 2, message_state: 2,
          item_list: [{type: 1, text_item: {text: $txt}}],
          context_token: $ctx},
    base_info: {channel_version: "0.1.0"}}')
curl -s --max-time 5 -X POST "${base_url%/}/ilink/bot/sendmessage" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${token}" \
  -H "AuthorizationType: ilink_bot_token" \
  -d "$req" >/dev/null 2>&1 || true

log "notify sent session=$session_id reason=${stop_reason:-unknown}"
rm -f "$session_file"
exit 0
