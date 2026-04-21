#!/usr/bin/env bash
# PreToolUse — 拦截阻塞性长时运行命令，提示改用 run_in_background=true + Monitor。
#
# 输入（stdin JSON，由 Claude Code 注入）:
#   { session_id, tool_name, tool_input: { command, run_in_background }, ... }
#
# 响应：
#   exit 0            — 放行（无输出）
#   exit 2 + JSON     — 阻止，{ decision: "block", reason: "..." }
#
# 依赖: jq

set -euo pipefail

HOOKS_DIR="${CLAUDE_WEIXIN_HOOKS_DIR:-$HOME/.cache/claude-weixin-channel/hooks}"
mkdir -p "$HOOKS_DIR"

LOG_FILE="$HOOKS_DIR/bg-guard.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ─── 读取 stdin ───────────────────────────────────────────────────────────────
payload=$(cat || true)
[[ -z "$payload" ]] && exit 0

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null || echo "")
[[ "$tool_name" != "Bash" ]] && exit 0

# 已设置 run_in_background=true，放行
run_in_bg=$(jq -r '.tool_input.run_in_background // false' <<<"$payload" 2>/dev/null || echo "false")
[[ "$run_in_bg" == "true" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null || echo "")
[[ -z "$command" ]] && exit 0

# ─── 规范化：去掉 VAR=value 前缀和 sudo，便于统一匹配 ────────────────────────
normalized="$command"
normalized=$(sed -E 's/^([A-Z_][A-Z0-9_]*=[^ ]+ +)+//' <<<"$normalized")
normalized=$(sed -E 's/^sudo( +-[^ ]+)* +//' <<<"$normalized")

# ─── 匹配规则 ─────────────────────────────────────────────────────────────────
is_blocking() {
  local cmd="$1"
  local patterns=(
    # watch（要求前导符，避免误匹配 --watch 标志）
    '(^|[|;&(] *| +(&&|\|\|) +)watch '
    # tail -f / --follow
    '\btail\b.* (-f\b|--follow\b)'
    # journalctl -f / --follow
    '\bjournalctl\b.* (-f\b|--follow\b)'
    # kubectl rollout status / kubectl wait
    '\bkubectl\b +(rollout +status|wait)\b'
    # npm/yarn/pnpm/bun dev
    '\b(npm|yarn|pnpm|bun)\b +run +dev\b'
    '\b(npm|yarn|pnpm|bun)\b +dev\b'
    # Python HTTP 服务器
    '\bpython[23]?\b.*-m +(http\.server|SimpleHTTPServer)\b'
    # ASGI/WSGI 服务器
    '\b(uvicorn|gunicorn)\b'
    # Flask dev server
    '\bflask\b +run\b'
  )
  for pat in "${patterns[@]}"; do
    grep -qEe "$pat" <<<"$cmd" 2>/dev/null && return 0
  done
  return 1
}

is_blocking "$normalized" || exit 0

# ─── 拦截 ─────────────────────────────────────────────────────────────────────
cmd_preview="${command:0:120}"
[[ "${#command}" -gt 120 ]] && cmd_preview="${cmd_preview}..."

session_id=$(jq -r '.session_id // ""' <<<"$payload" 2>/dev/null || echo "")
log "block session=${session_id:0:8} cmd=${command:0:80}"

reason=$(cat <<REASON
检测到可能长时阻塞的命令：${cmd_preview}

微信消息桥接期间，此类命令会占用进程无法响应新消息。请改用后台模式：

  run_in_background: true

然后用 Monitor 工具持续观察输出。示例：

  # 第一步：后台启动
  Bash(command="kubectl rollout status deployment/my-app", run_in_background=true)

  # 第二步：Monitor 订阅输出
  Monitor(process_id=<上一步返回的 process_id>)

如只需一次性检查，请改用非跟踪形式（不加 -f）：
  tail -n 50 /var/log/app.log
  journalctl -n 100 --no-pager
REASON
)

jq -n --arg r "$reason" '{"decision":"block","reason":$r}'
exit 2
