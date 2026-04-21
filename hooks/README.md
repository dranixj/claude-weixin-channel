# Hooks — WeChat × Claude Code 体验增强

五个 bash 脚本，解决 cc-wechat 家族在实际使用中的体验痛点。详细设计见
[dranixj 的文章](https://dranixj.com/articles/cc-wechat-hooks-enhance-claude-code-wechat-experience)。

| Hook | Claude Code 事件 | 作用 |
|------|-----------------|------|
| `wechat-bg-guard.sh` | `PreToolUse` (Bash) | 拦截阻塞性长时运行命令（watch、tail -f、dev server 等），提示改用后台模式 |
| `wechat-ack.sh` | `UserPromptSubmit` | 即时发送"收到，处理中..."；持久化会话状态；支持斜杠命令和模式切换 |
| `wechat-progress.sh` | `PostToolUse` | 工具执行进度实时推送（需 `/progress on`） |
| `wechat-stream.sh` | `PostChunk` | Claude 流式输出实时转发到微信（默认开启）|
| `wechat-stop-notify.sh` | `Stop` | 若处理中断（无完整 reply），推送异常通知 |

> 原文里的第四个脚本 `wechat-reply-fix.sh`（`PreToolUse` 清洗 XML 污染）已经内置到
> `src/server.ts` 的 `sanitizeReplyArgs()`，无需再以 hook 形式部署。

## 后台命令守卫（bg-guard）

`wechat-bg-guard.sh` 在 Claude 调用 Bash 工具之前运行。若命令是长时阻塞型，且 `run_in_background` 未设为 `true`，hook 会阻止执行并提示 Claude 改用后台模式。

**拦截的命令模式：**

| 模式 | 示例 |
|------|------|
| `watch` 命令 | `watch kubectl get pods` |
| `tail -f` / `tail --follow` | `tail -f /var/log/app.log` |
| `journalctl -f` / `--follow` | `journalctl -f -u nginx` |
| `kubectl rollout status` / `kubectl wait` | `kubectl rollout status deploy/app` |
| `npm/yarn/pnpm/bun dev` | `npm run dev`、`bun dev` |
| Python HTTP 服务器 | `python3 -m http.server 8080` |
| ASGI/WSGI 服务器 | `uvicorn app:main`、`gunicorn -w 4 app:app` |
| Flask dev server | `flask run` |

**不拦截（单次执行命令）：**

`npm run build`、`npm test`、`pytest`、`make`、`docker build`、`tail -n 50 file.log`

**自动放行条件：**

- `run_in_background: true` 已设置
- 工具名不是 `Bash`（matcher 为 `Bash`）

**日志：** `~/.cache/claude-weixin-channel/hooks/bg-guard.log`（仅在拦截时写入）

## 斜杠命令

`wechat-ack.sh` 支持以下命令，在微信中直接发送即可：

| 命令 | 说明 |
|------|------|
| `/new` | 开始新话题（清除 transcript 链接） |
| `/clear` | 清空编辑器上下文（截断 transcript 文件） |
| `/mode <name>` | 切换角色模式：`code` (工程师) / `review` (代码审查) / `explain` (教师) / `concise` (简洁) / `off` (默认) |
| `/compact` | 精简响应模式（等同 `/mode compact`） |
| `/think` | 开启深度思考模式 |
| `/stream on\|off` | 切换流式转发（默认 on） |
| `/progress on\|off` | 切换工具进度通知（默认 off） |
| `/session-status` | 查看当前会话状态：session ID、profile、当前 mode、stream/progress 设置 |
| `/help` | 显示可用命令列表 |

### 会话状态持久化

所有会话状态保存在 `~/.cache/claude-weixin-channel/hooks/${session_id}.session.json`：

```json
{
  "user_id": "...",
  "context_token": "...",
  "mode": "code",
  "mode_ctx": "# System\nAct as a senior software engineer...",
  "stream_notify": true,
  "progress_notify": false
}
```

状态在 `UserPromptSubmit` 时读取，在处理后自动保存，跨多个请求持久化。

## 一键安装

```bash
npx claude-weixin-channel install-hooks
```

执行内容：

1. 复制 `wechat-*.sh` 到 `~/.claude/hooks/`，赋予可执行权限
2. 读取 `~/.claude/settings.json`（不存在则创建），**合并** hook 条目
3. 原文件备份为 `~/.claude/settings.json.bak`

卸载：

```bash
npx claude-weixin-channel uninstall-hooks
```

仅从 `settings.json` 中移除本项目的 hook 条目，脚本文件保留以便排查日志（`~/.cache/claude-weixin-channel/hooks/*.log`）。

## 依赖

- `jq`
- `curl`
- `python3`（只在 `wechat-ack.sh` 中用一次，做稳妥的多行 `<channel>` 正文提取）

## 状态目录

所有跨 hook 共享的状态默认写在 `$HOME/.cache/claude-weixin-channel/hooks/`：

- `${session_id}.session.json` — `wechat-ack` 写入，记录 user_id / context_token / profile
- `${session_id}.replied` — `wechat-reply-sent` 写入的标记文件
- `ack.log`, `stop.log` — 调试日志

可用环境变量 `CLAUDE_WEIXIN_HOOKS_DIR` 覆盖。

## 手动安装（不用 CLI）

把五个 `.sh` 复制到 `~/.claude/hooks/`，`chmod +x`，然后把下方 hooks 片段合并到 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-bg-guard.sh", "timeout": 5 }
      ]}
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-ack.sh", "timeout": 10 }
      ]}
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-progress.sh", "timeout": 5 }
      ]},
      { "matcher": "mcp__wechat-channel__reply", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-reply-sent.sh", "timeout": 5 }
      ]}
    ],
    "PostChunk": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-stream.sh", "timeout": 2 }
      ]}
    ],
    "Stop": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-stop-notify.sh", "timeout": 10 }
      ]}
    ]
  }
}
```

## 设计取舍

- **为什么 reply-fix 不做成 hook？** 我们拥有这个 fork，在 MCP server 的 `reply` 处理函数里清洗更直接，避免外部 jq 脚本、避免跨进程 IO，且版本锁定。原文把它做成 PreToolUse hook 是因为他们不能改 cc-wechat 源码。
- **为什么 ack 还是 hook？** `UserPromptSubmit` 是 Claude Code 生命周期事件，MCP server 不可见。server 虽然会在收到消息时发 typing 指示，但"Claude 真正开始处理"才是 ack 的准确时机。
- **为什么 stop-notify 是 hook？** 同理，Claude Code 的 Stop 事件只能在 hook 里拿到。
