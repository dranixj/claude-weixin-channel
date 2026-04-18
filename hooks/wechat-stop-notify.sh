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

# 通知后台 stream 进程优雅退出（无论是否已 replied）
touch "$HOOKS_DIR/${session_id}.stream.stop" 2>/dev/null || true

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
  ""|unknown|end_turn|stop_sequence|tool_use)
    # 正常结束：Claude 用纯文本回复（由 stream 转发）而非 reply 工具，
    # 没有 .replied 标记不代表异常。静默清理，不打扰用户。
    log "normal stop session=$session_id reason=${stop_reason:-empty}; no notify"
    rm -f "$session_file"
    exit 0
    ;;
  *)
    msg="⚠️ 处理中断（原因：${stop_reason}）。"
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

cid="cc-stop-$(openssl rand -hex 4 2>/dev/null || echo $$)"
uin=$(echo -n "$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')" | base64)
req=$(jq -n \
  --arg to "$user_id" --arg ctx "$context_token" --arg txt "$msg" --arg cid "$cid" \
  '{msg: {from_user_id: "", to_user_id: $to, client_id: $cid,
          message_type: 2, message_state: 2,
          item_list: [{type: 1, text_item: {text: $txt}}],
          context_token: $ctx},
    base_info: {channel_version: "0.1.0"}}')
resp=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST "${base_url%/}/ilink/bot/sendmessage" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${token}" \
  -H "AuthorizationType: ilink_bot_token" \
  -H "X-WECHAT-UIN: ${uin}" \
  -d "$req" 2>&1) || true
http_code="${resp##*$'\n'}"
[[ "$http_code" != "200" ]] && log "send non-200 http=$http_code body=${resp%$'\n'*}"

log "notify sent session=$session_id reason=${stop_reason:-unknown}"
rm -f "$session_file"
exit 0
