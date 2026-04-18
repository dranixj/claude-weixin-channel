#!/usr/bin/env bash
# 后台流式转发脚本 — 由 wechat-ack.sh 以 nohup 方式启动。
#
# 作用: 轮询 transcript_path（JSONL），将 assistant 消息中的 text block 通过
# iLink sendmessage 实时推送到微信，让用户在处理过程中看到 Claude 的中间输出。
#
# 退出条件: .stream.stop 标记存在 / 运行超过 MAX_RUNTIME / transcript 消失。
#
# 用法: wechat-stream.sh <session_id> <user_id> <context_token> <profile> <transcript_path>
# 依赖: jq, curl, python3

set -u

SESSION_ID="${1:-}"
USER_ID="${2:-}"
CONTEXT_TOKEN="${3:-}"
PROFILE="${4:-default}"
TRANSCRIPT_PATH="${5:-}"

[[ -z "$SESSION_ID" || -z "$USER_ID" || -z "$CONTEXT_TOKEN" ]] && exit 0

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"

STOP_MARKER="$HOOKS_DIR/${SESSION_ID}.stream.stop"
PID_FILE="$HOOKS_DIR/${SESSION_ID}.stream.pid"
STATE_FILE="$HOOKS_DIR/${SESSION_ID}.session.json"
REPLIED_MARKER="$HOOKS_DIR/${SESSION_ID}.replied"
LOG_FILE="$HOOKS_DIR/stream.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

on_exit() {
  rm -f "$PID_FILE" "$STOP_MARKER" 2>/dev/null || true
  log "exit session=$SESSION_ID"
}
trap on_exit EXIT TERM INT

# ─── 凭证 ────────────────────────────────────────────
account_file="$HOME/.claude/channels/wechat/$PROFILE/account.json"
[[ ! -f "$account_file" ]] && { log "no account file"; exit 0; }
TOKEN=$(jq -r '.token // ""' "$account_file" 2>/dev/null || echo "")
BASE_URL=$(jq -r '.baseUrl // "https://ilinkai.weixin.qq.com"' "$account_file" 2>/dev/null || echo "https://ilinkai.weixin.qq.com")
[[ -z "$TOKEN" ]] && { log "empty token"; exit 0; }

# ─── iLink 发送 ──────────────────────────────────────
rand_uin() { echo -n "$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')" | base64; }

send_chunk() {
  local text="$1" req cid uin http_code body
  cid="cc-stream-$(openssl rand -hex 4 2>/dev/null || echo $$)"
  uin=$(rand_uin)
  req=$(jq -n --arg to "$USER_ID" --arg ctx "$CONTEXT_TOKEN" --arg txt "$text" --arg cid "$cid" \
    '{msg: {from_user_id: "", to_user_id: $to, client_id: $cid,
            message_type: 2, message_state: 2,
            item_list: [{type: 1, text_item: {text: $txt}}],
            context_token: $ctx},
      base_info: {channel_version: "0.1.0"}}' 2>/dev/null) || return 0
  body=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST "${BASE_URL%/}/ilink/bot/sendmessage" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "AuthorizationType: ilink_bot_token" \
    -H "X-WECHAT-UIN: ${uin}" \
    -d "$req" 2>&1) || { log "send FAILED curl_exit=$?"; return 0; }
  http_code="${body##*$'\n'}"
  [[ "$http_code" != "200" ]] && log "send non-200 http=$http_code body=${body%$'\n'*}"
}

send_text() {
  local text="$1" max=3900
  while [[ ${#text} -gt 0 ]]; do
    send_chunk "${text:0:$max}"
    text="${text:$max}"
  done
  touch "$REPLIED_MARKER" 2>/dev/null || true
}

# ─── 从 JSONL 提取 assistant text block（b64 行输出） ───
extract_texts() {
  local from_line="$1"
  tail -n +"$from_line" "$TRANSCRIPT_PATH" 2>/dev/null | python3 -c '
import json, sys, base64
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        entry = json.loads(raw)
    except Exception:
        continue
    if entry.get("type") != "assistant":
        continue
    content = entry.get("message", {}).get("content", [])
    if not isinstance(content, list):
        continue
    # 跳过含 reply tool_use 的消息：reply 本身会投递权威文本，避免重复
    has_reply = any(
        isinstance(b, dict)
        and b.get("type") == "tool_use"
        and b.get("name") == "mcp__wechat-channel__reply"
        for b in content
    )
    if has_reply:
        continue
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            text = (block.get("text") or "").strip()
            if text:
                print(base64.b64encode(text.encode("utf-8")).decode("ascii"))
' 2>/dev/null || true
}

# ─── 主循环 ──────────────────────────────────────────
# 起点：从当前 transcript 末尾开始（不回放 UserPromptSubmit 之前的历史）
last_line=0
if [[ -f "$TRANSCRIPT_PATH" ]]; then
  last_line=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
fi

MAX_RUNTIME=600
start_ts=$(date +%s)
log "start session=$SESSION_ID transcript=$TRANSCRIPT_PATH start_line=$last_line"

while true; do
  [[ -f "$STOP_MARKER" ]] && break
  now=$(date +%s)
  if (( now - start_ts > MAX_RUNTIME )); then
    log "timeout"; break
  fi

  # 动态刷新 context_token（若用户发送了新消息，wechat-ack 已更新 session.json）
  if [[ -f "$STATE_FILE" ]]; then
    ctx=$(jq -r '.context_token // ""' "$STATE_FILE" 2>/dev/null || echo "")
    [[ -n "$ctx" ]] && CONTEXT_TOKEN="$ctx"
    # 若 stream_notify 被关闭，优雅退出
    sn=$(jq -r 'if .stream_notify == null then "true" else (.stream_notify | tostring) end' "$STATE_FILE" 2>/dev/null || echo "true")
    [[ "$sn" != "true" ]] && { log "stream_notify disabled"; break; }
  fi

  if [[ -f "$TRANSCRIPT_PATH" ]]; then
    total_lines=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    if (( total_lines > last_line )); then
      b64_list=$(extract_texts $((last_line + 1)))
      while IFS= read -r b64; do
        [[ -z "$b64" ]] && continue
        text=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
        [[ -n "$text" ]] && send_text "$text"
      done <<< "$b64_list"
      last_line=$total_lines
    fi
  fi

  sleep 2
done
