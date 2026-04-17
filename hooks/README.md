# Hooks — WeChat × Claude Code 体验增强

三个 bash 脚本，解决 cc-wechat 家族在实际使用中的体验痛点。详细设计见
[dranixj 的文章](https://dranixj.com/articles/cc-wechat-hooks-enhance-claude-code-wechat-experience)。

| Hook | Claude Code 事件 | 作用 |
|------|-----------------|------|
| `wechat-ack.sh` | `UserPromptSubmit` | 即时发送"收到，处理中..."；持久化会话状态；支持 `/new` `/help` `/status` |
| `wechat-reply-sent.sh` | `PostToolUse` | `mcp__wechat-channel__reply` 成功后写入 `.replied` 标记 |
| `wechat-stop-notify.sh` | `Stop` | 若未命中 `.replied`，推送"处理中断"通知，覆盖用量耗尽等异常 |

> 原文里的第四个脚本 `wechat-reply-fix.sh`（`PreToolUse` 清洗 XML 污染）已经内置到
> `src/server.ts` 的 `sanitizeReplyArgs()`，无需再以 hook 形式部署。

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

把三个 `.sh` 复制到 `~/.claude/hooks/`，`chmod +x`，然后把下方 hooks 片段合并到 `~/.claude/settings.json`：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-ack.sh", "timeout": 10 }
      ]}
    ],
    "PostToolUse": [
      { "matcher": "mcp__wechat-channel__reply", "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/wechat-reply-sent.sh", "timeout": 5 }
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
