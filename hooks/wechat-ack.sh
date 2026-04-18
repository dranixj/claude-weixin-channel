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
transcript_path=$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null || echo "")

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

rand_uin() { echo -n "$(od -An -tu4 -N4 /dev/urandom | tr -d ' ')" | base64; }

send_wechat_msg() {
  local text="$1" req http_code body cid uin
  cid="cc-hook-$(openssl rand -hex 4 2>/dev/null || echo $$)"
  uin=$(rand_uin)
  req=$(jq -n \
    --arg to "$user_id" --arg ctx "$context_token" --arg txt "$text" --arg cid "$cid" \
    '{msg: {from_user_id: "", to_user_id: $to, client_id: $cid,
            message_type: 2, message_state: 2,
            item_list: [{type: 1, text_item: {text: $txt}}],
            context_token: $ctx},
      base_info: {channel_version: "0.1.0"}}')
  body=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST "${base_url%/}/ilink/bot/sendmessage" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -H "AuthorizationType: ilink_bot_token" \
    -H "X-WECHAT-UIN: ${uin}" \
    -d "$req" 2>&1) || { log "send FAILED curl_exit=$? ctx=${context_token:0:12}"; return 0; }
  http_code="${body##*$'\n'}"
  if [[ "$http_code" != "200" ]]; then
    log "send non-200 http=$http_code body=${body%$'\n'*}"
  fi
}

# ─── 读取已有 session 状态（用于持久化 mode / progress_notify / stream_notify） ───
state_file="$HOOKS_DIR/${session_id}.session.json"
prior_mode="default"
prior_mode_ctx=""
prior_progress_notify="false"
prior_stream_notify="true"
if [[ -f "$state_file" ]]; then
  prior_mode=$(jq -r '.mode // "default"' "$state_file" 2>/dev/null || echo "default")
  prior_mode_ctx=$(jq -r '.mode_ctx // ""' "$state_file" 2>/dev/null || echo "")
  prior_progress_notify=$(jq -r '.progress_notify // false' "$state_file" 2>/dev/null || echo "false")
  prior_stream_notify=$(jq -r 'if .stream_notify == null then "true" else (.stream_notify | tostring) end' "$state_file" 2>/dev/null || echo "true")
fi

ack_text="收到，处理中..."
hook_decision=""
additional_ctx=""
next_mode="$prior_mode"
next_mode_ctx="$prior_mode_ctx"
next_progress_notify="$prior_progress_notify"
next_stream_notify="$prior_stream_notify"

# ─── Slash 命令处理 ───
case "$body" in
  /new|/new\ *)
    ack_text="✅ 已开始新话题。"
    additional_ctx="# System
The user sent '/new'. Ignore any previous conversation context and treat this as a fresh topic. Acknowledge briefly."
    ;;
  /help|/help\ *)
    ack_text=$'可用命令：\n/new     开始新话题\n/clear   清空上下文（截断 transcript）\n/mode <name>  切换角色（code/review/explain/concise/off）\n/compact 精简响应\n/think   开启深度思考\n/stream  切换流式转发（默认开启）\n/progress 切换工具进度通知\n/session-status  查看运行状态\n/help    显示帮助\n其他消息转给 Claude Code 处理。'
    hook_decision="block"
    ;;
  /session-status|/session-status\ *)
    ack_text="Claude Code 运行中
session: ${session_id:0:8}
profile: ${profile}
mode: ${prior_mode}
stream: ${prior_stream_notify}
progress: ${prior_progress_notify}"
    hook_decision="block"
    ;;
  /stream|/stream\ on|/stream\ off)
    case "$body" in
      "/stream on")  next_stream_notify="true"  ;;
      "/stream off") next_stream_notify="false" ;;
      *)
        if [[ "$prior_stream_notify" == "true" ]]; then
          next_stream_notify="false"
        else
          next_stream_notify="true"
        fi
        ;;
    esac
    if [[ "$next_stream_notify" == "true" ]]; then
      ack_text="✅ 流式转发已开启，Claude 的中间输出会实时推送。"
    else
      ack_text="✅ 流式转发已关闭。"
    fi
    hook_decision="block"
    ;;
  /compact|/compact\ *)
    ack_text="✅ 已切换到精简模式。"
    next_mode="compact"
    next_mode_ctx="# System
User requested '/compact' mode. Keep responses concise: summarize reasoning rather than showing it, aim for under 500 characters when possible."
    additional_ctx="$next_mode_ctx"
    ;;
  /think|/think\ *)
    ack_text="✅ 已开启深度思考模式。"
    next_mode="think"
    next_mode_ctx="# System
User requested '/think' mode. Think step by step carefully before answering. Show key reasoning steps explicitly when relevant."
    additional_ctx="$next_mode_ctx"
    ;;
  /mode|/mode\ *)
    mode_arg="${body#/mode}"
    mode_arg="${mode_arg# }"
    case "$mode_arg" in
      code)
        next_mode="code"
        next_mode_ctx="# System
Act as a senior software engineer. Prioritize code quality, test coverage, and best practices. Discuss trade-offs when relevant."
        ack_text="✅ 已切换到 code 模式。"
        ;;
      review)
        next_mode="review"
        next_mode_ctx="# System
Act as a critical code reviewer. Point out bugs, security issues, performance problems, and maintainability concerns."
        ack_text="✅ 已切换到 review 模式。"
        ;;
      explain)
        next_mode="explain"
        next_mode_ctx="# System
Act as a patient teacher. Explain concepts simply with examples, check for understanding, avoid jargon when possible."
        ack_text="✅ 已切换到 explain 模式。"
        ;;
      concise)
        next_mode="concise"
        next_mode_ctx="# System
Be extremely concise. Max 3 sentences per response unless asked for more detail."
        ack_text="✅ 已切换到 concise 模式。"
        ;;
      off|default|reset|"")
        next_mode="default"
        next_mode_ctx=""
        ack_text="✅ 已清除模式。"
        ;;
      *)
        ack_text="可用 mode：code / review / explain / concise / off
用法：/mode <name>"
        ;;
    esac
    hook_decision="block"
    ;;
  /clear|/clear\ *)
    if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
      # 直接截断 transcript 文件；UserPromptSubmit 时 Claude 未开始处理，窗口安全
      : > "$transcript_path" 2>/dev/null || true
      ack_text="✅ 上下文已清空，开始新对话。"
      log "cleared transcript session=$session_id path=$transcript_path"
    else
      ack_text="✅ 已请求清空（transcript 路径未提供，使用心理清理）。"
    fi
    hook_decision="block"
    ;;
  /progress|/progress\ on|/progress\ off)
    case "$body" in
      "/progress on")  next_progress_notify="true"  ;;
      "/progress off") next_progress_notify="false" ;;
      *)
        # 无参数：翻转
        if [[ "$prior_progress_notify" == "true" ]]; then
          next_progress_notify="false"
        else
          next_progress_notify="true"
        fi
        ;;
    esac
    if [[ "$next_progress_notify" == "true" ]]; then
      ack_text="✅ 进度通知已开启，每次工具调用完成会推送摘要。"
    else
      ack_text="✅ 进度通知已关闭。"
    fi
    hook_decision="block"
    ;;
  "")
    # 空正文（如纯表情/图片），直接发送默认 ack
    ;;
  *)
    # 非命令消息：如有已持久化的 mode_ctx，注入为 additionalContext
    if [[ -n "$prior_mode_ctx" ]]; then
      additional_ctx="$prior_mode_ctx"
    fi
    ;;
esac

send_wechat_msg "$ack_text"
log "ack sent session=$session_id user=$user_id msg_id=$message_id mode=$next_mode body_head=${body:0:40}"

# 持久化会话状态（供 Stop/Progress hook 使用）
jq -n \
  --arg uid "$user_id" \
  --arg ctx "$context_token" \
  --arg mid "$message_id" \
  --arg profile "$profile" \
  --arg mode "$next_mode" \
  --arg mode_ctx "$next_mode_ctx" \
  --arg progress "$next_progress_notify" \
  --arg stream "$next_stream_notify" \
  --arg tpath "$transcript_path" \
  '{user_id:$uid, context_token:$ctx, message_id:$mid, profile:$profile,
    mode:$mode, mode_ctx:$mode_ctx,
    progress_notify:($progress == "true"),
    stream_notify:($stream == "true"),
    transcript_path:$tpath,
    updated_at: (now | todate)}' \
  > "$state_file"

# ─── 启动/重启后台 stream 转发进程 ───
# 条件：stream 已开启、有 transcript 路径、本条非 block 类 slash 命令
if [[ "$next_stream_notify" == "true" && -n "$transcript_path" && "$hook_decision" != "block" ]]; then
  stream_script="$HOME/.claude/hooks/wechat-stream.sh"
  pid_file="$HOOKS_DIR/${session_id}.stream.pid"
  # 杀掉上一轮残留的 stream 进程（如存在）
  if [[ -f "$pid_file" ]]; then
    old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    [[ -n "$old_pid" ]] && kill "$old_pid" 2>/dev/null || true
  fi
  # 清掉旧的 stop 标记
  rm -f "$HOOKS_DIR/${session_id}.stream.stop" 2>/dev/null || true
  if [[ -x "$stream_script" ]]; then
    nohup bash "$stream_script" "$session_id" "$user_id" "$context_token" "$profile" "$transcript_path" \
      >/dev/null 2>&1 &
    new_pid=$!
    disown "$new_pid" 2>/dev/null || true
    printf '%s' "$new_pid" > "$pid_file" 2>/dev/null || true
    log "stream spawned pid=$new_pid"
  fi
fi

# 返回 hook 响应
if [[ "$hook_decision" == "block" ]]; then
  jq -n --arg r "slash command handled by wechat-ack hook" \
    '{decision:"block", reason:$r}'
elif [[ -n "$additional_ctx" ]]; then
  jq -n --arg c "$additional_ctx" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}'
fi
exit 0
