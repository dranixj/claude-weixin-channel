#!/usr/bin/env bash
# PostToolUse hook — 将每次工具调用的进度摘要推送到微信。
#
# 默认关闭，仅当 session.json 的 progress_notify=true 时发送（通过 /progress 命令切换）。
# 为防刷屏和 iLink 限流，距上次发送 < 1s 时跳过。
#
# 输入 (stdin JSON):
#   { session_id, tool_name, tool_input, tool_response, hook_event_name }

set -euo pipefail

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"

LOG_FILE="$HOOKS_DIR/progress.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

payload=$(cat || true)
[[ -z "$payload" ]] && exit 0

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null || echo "")
session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || echo "")
[[ -z "$tool_name" || -z "$session_id" ]] && exit 0

# 过滤 wechat-channel 自身工具，避免递归/噪音
case "$tool_name" in
  mcp__wechat-channel__reply|mcp__wechat-channel__login) exit 0 ;;
esac

state_file="$HOOKS_DIR/${session_id}.session.json"
[[ ! -f "$state_file" ]] && exit 0

progress_notify=$(jq -r '.progress_notify // false' "$state_file" 2>/dev/null || echo "false")
[[ "$progress_notify" != "true" ]] && exit 0

user_id=$(jq -r '.user_id // ""' "$state_file")
context_token=$(jq -r '.context_token // ""' "$state_file")
profile=$(jq -r '.profile // "default"' "$state_file")
[[ -z "$user_id" || -z "$context_token" ]] && exit 0

# 速率保护：距上次发送 < 1s 跳过
rate_file="$HOOKS_DIR/${session_id}.progress.ts"
now=$(date +%s)
if [[ -f "$rate_file" ]]; then
  last=$(cat "$rate_file" 2>/dev/null || echo 0)
  diff=$(( now - last ))
  if (( diff < 1 )); then
    log "rate-skip session=$session_id tool=$tool_name diff=${diff}s"
    exit 0
  fi
fi

# 账号凭证
account_file="$HOME/.claude/channels/wechat/$profile/account.json"
[[ ! -f "$account_file" ]] && exit 0
token=$(jq -r '.token // ""' "$account_file")
base_url=$(jq -r '.baseUrl // "https://ilinkai.weixin.qq.com"' "$account_file")
[[ -z "$token" ]] && exit 0

# 工具输入摘要（取最相关的字段，截断到 80 字符）
summarize_input() {
  local tn="$1" input
  input=$(jq -r '.tool_input // {}' <<<"$payload" 2>/dev/null || echo "{}")
  case "$tn" in
    Bash)
      jq -r '.command // ""' <<<"$input" | head -c 80
      ;;
    Read|Write|Edit|NotebookEdit)
      jq -r '.file_path // ""' <<<"$input" | head -c 80
      ;;
    Grep|Glob)
      jq -r '.pattern // ""' <<<"$input" | head -c 80
      ;;
    *)
      jq -c '.' <<<"$input" 2>/dev/null | head -c 80
      ;;
  esac
}

input_summary=$(summarize_input "$tool_name")
is_error=$(jq -r '.tool_response.isError // false' <<<"$payload" 2>/dev/null || echo "false")
status_icon="✓"
[[ "$is_error" == "true" ]] && status_icon="✗"

# 工具名去掉 mcp__ 前缀显得更紧凑
short_tool="${tool_name#mcp__}"

msg="[${short_tool}] ${input_summary} ${status_icon}"

cid="cc-prog-$(openssl rand -hex 4 2>/dev/null || echo $$)"
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

echo "$now" > "$rate_file"
log "progress sent session=$session_id tool=$tool_name status=$status_icon"
exit 0
