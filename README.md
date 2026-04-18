# claude-weixin-channel

用微信控制 Claude Code。扫码即用，不需要 OpenClaw。

> Fork of [paceaitian/cc-wechat](https://github.com/paceaitian/cc-wechat)（MIT）。
> 本分支计划叠加一组 Hook 脚本，解决"消息无反馈 / reply 参数被污染 / 用量耗尽时无应答"三个体验痛点，详见 [dranixj 的文章](https://dranixj.com/articles/cc-wechat-hooks-enhance-claude-code-wechat-experience)。Hook 能力会在后续版本落地，当前版本与上游 `cc-wechat` 功能等价。

```
微信 → 腾讯 iLink API → MCP Server (long-poll) → Claude Code
                       ← sendMessage              ← reply tool
```

底层直接调用腾讯的 iLink Bot API，不依赖 OpenClaw。

## 前提

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v2.1.80+
- Node.js >= 22
- 微信（iOS / Android / Mac / Windows 均可扫码）

## 快速开始

### 1. 安装微信插件

    npx claude-weixin-channel@latest install

这会：
1. 注册 MCP server 到 Claude Code（user 级别）
2. 在终端显示二维码，微信扫码登录
3. 打印启动命令

### 2. 启用 Channels 功能（如遇 "Channels are not currently available"）

Claude Code 的 Channels 功能受服务端灰度控制，部分用户需要 patch 才能使用：

    npx claude-weixin-channel@latest patch

- 全平台支持：Windows / macOS / Linux / WSL
- 全安装方式：native 安装版、npm 安装版（自动检测）
- 正则匹配，适配所有 CC 版本，无需手动更新
- 如果 CC 正在运行会生成 `.patched` 文件，按提示手动替换即可
- 恢复原版：`npx claude-weixin-channel unpatch`

> 也可用独立的零依赖补丁包 [`claude-weixin-channel-patch`](./packages/claude-weixin-channel-patch)（fork 自上游 `cc-channel-patch`），效果等价。

### 3. 启动

    claude --dangerously-load-development-channels server:wechat-channel

### 手动安装（替代方式）

    npm i -g claude-weixin-channel
    claude mcp add -s user wechat-channel -- npx -y claude-weixin-channel@latest
    npx claude-weixin-channel login
    claude --dangerously-load-development-channels server:wechat-channel

## 使用

登录后，在微信里发消息，Claude Code 会实时收到并处理。Claude 通过 reply 工具回复，消息会出现在你的微信对话里。

支持发送图片、视频和文件（通过 reply 工具的 media 参数）。

### 重新登录

    npx claude-weixin-channel login

### 在 Claude Code 中登录

如果已经在 Claude Code 中，直接用 login 工具扫码。

## 工作原理

直接调用腾讯的 iLink Bot API（7 个 HTTP 接口）：

| API | 功能 |
|-----|------|
| get_bot_qrcode | 获取登录二维码 |
| get_qrcode_status | 轮询扫码状态 |
| getupdates | 长轮询收消息（35s 超时） |
| sendmessage | 发送消息 |
| sendtyping | 打字状态指示 |
| getconfig | 获取 typing ticket |
| getuploadurl | 获取 CDN 上传签名（媒体发送）|

## 多账号（项目级绑定）

通过 `WECHAT_PROFILE` 环境变量，不同项目可以绑定不同的微信号：

```json
// 项目 .mcp.json
{
  "mcpServers": {
    "wechat-channel": {
      "command": "npx",
      "args": ["-y", "claude-weixin-channel@latest"],
      "env": { "WECHAT_PROFILE": "work" }
    }
  }
}
```

每个 profile 独立存储凭证和会话：

```
~/.claude/channels/wechat/
├── default/           # 默认账号（未设 WECHAT_PROFILE 时使用）
│   ├── account.json
│   └── sync-buf.txt
├── work/              # WECHAT_PROFILE=work
│   ├── account.json
│   └── sync-buf.txt
└── personal/          # WECHAT_PROFILE=personal
    ├── account.json
    └── sync-buf.txt
```

- 全局 `claude.json` 的配置作为默认账号，不需要设 `WECHAT_PROFILE`
- 项目 `.mcp.json` 中声明同名 `wechat-channel` 会覆盖全局配置
- 新 profile 首次使用需扫码登录（在 CC 中调用 login 工具，或命令行 `WECHAT_PROFILE=work npx claude-weixin-channel login`）

## 状态文件

    ~/.claude/channels/wechat/<profile>/
    ├── account.json     # 登录凭证
    └── sync-buf.txt     # 消息同步游标

## Hooks 体验增强

在安装步骤之后再跑一次：

    npx claude-weixin-channel install-hooks

即可把四个生命周期 hook 合并进 `~/.claude/settings.json`（原文件自动备份为 `.bak`）：

| 脚本 | 事件 | 作用 |
|------|------|------|
| `wechat-ack.sh` | `UserPromptSubmit` | 即时回复 "收到，处理中..."；持久化会话状态；支持斜杠命令 |
| `wechat-progress.sh` | `PostToolUse` | 工具执行进度实时推送到微信 |
| `wechat-stream.sh` | `PostChunk` | Claude 流式输出实时转发到微信 |
| `wechat-stop-notify.sh` | `Stop` | 未命中 `.replied` 时向微信推送"处理中断"通知（用量耗尽等异常） |

### 斜杠命令

在微信对话中发送以下命令控制行为：

- `/new` — 开始新话题（清除上下文链接）
- `/clear` — 清空编辑器上下文（截断 transcript）
- `/mode <name>` — 切换角色模式（code/review/explain/concise/off）
- `/compact` — 精简响应模式
- `/think` — 开启深度思考模式
- `/stream on|off` — 切换流式转发（默认开启）
- `/progress on|off` — 切换工具进度通知（默认关闭）
- `/session-status` — 查看当前会话状态
- `/help` — 显示帮助信息

> 原文里第四个脚本 `wechat-reply-fix.sh`（`PreToolUse` 清洗 XML 污染）已内置到 MCP server 的
> `sanitizeReplyArgs()`，无需外部 hook。

卸载：`npx claude-weixin-channel uninstall-hooks`

更多设计说明与环境变量见 [hooks/README.md](./hooks/README.md)。

## 路线图

- [ ] 与上游 `cc-wechat` 的 upstream 跟踪合并策略
- [ ] Hook 的 Windows 原生（非 WSL）支持

## 限制

- 权限审批仍需在终端（Claude Code 的固有限制）
- 语音消息仅提取转写文本
- Session 会过期，需重新扫码
- 需要用户先发消息（context_token 按消息发放）
- 部分模型（如 GLM-4.7）不支持图片输入，发送图片时需使用支持 vision 的模型

## 鸣谢

- 上游项目：[paceaitian/cc-wechat](https://github.com/paceaitian/cc-wechat)
- Hook 增强思路来源：[dranixj 的文章](https://dranixj.com/articles/cc-wechat-hooks-enhance-claude-code-wechat-experience)
- npm 包的 patch 由 linuxdo 哈雷佬 @Haleclipse 率先发布的方式修改而来
- 学 AI 上 [Linux.do](https://linux.do)

## License

MIT — 见 [LICENSE](./LICENSE) 与 [NOTICE](./NOTICE)。保留了上游 cc-wechat 的版权声明。
