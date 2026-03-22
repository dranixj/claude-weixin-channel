# cc-wechat

用微信控制 Claude Code。扫码即用，不需要 OpenClaw。

## 架构

微信用户发消息 → iLink Bot API (ilinkai.weixin.qq.com) → cc-wechat MCP Server → Claude Code
Claude Code → reply tool → cc-wechat MCP Server → iLink Bot API → 微信用户

底层直接调用腾讯的 iLink Bot API，不依赖 OpenClaw。

## 前提

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) v2.1.80+
- Node.js >= 22
- 微信（iOS / Android / Mac / Windows 均可扫码）

## 安装

### 一键安装

    npx cc-wechat install

这会：
1. 注册 MCP server 到 Claude Code（user 级别）
2. 在终端显示二维码，微信扫码登录
3. 打印启动命令

### 启动

    claude --dangerously-load-development-channels server:wechat-channel

### 手动安装

    npm i -g cc-wechat
    claude mcp add -s user wechat-channel node $(which cc-wechat-server)
    npx cc-wechat login
    claude --dangerously-load-development-channels server:wechat-channel

## 使用

登录后，在微信里发消息，Claude Code 会实时收到并处理。Claude 通过 reply 工具回复，消息会出现在你的微信对话里。

支持发送图片、视频和文件（通过 reply 工具的 media 参数）。

### 重新登录

    npx cc-wechat login

### 在 Claude Code 中登录

如果已经在 Claude Code 中，直接用 login 工具扫码。

## 工作原理

直接调用腾讯的 iLink Bot API（6 个 HTTP 接口）：

| API | 功能 |
|-----|------|
| get_bot_qrcode | 获取登录二维码 |
| get_qrcode_status | 轮询扫码状态 |
| getupdates | 长轮询收消息（35s 超时） |
| sendmessage | 发送消息 |
| sendtyping | 打字状态指示 |
| getconfig | 获取 typing ticket |

## 状态文件

    ~/.claude/channels/wechat/
    ├── account.json     # 登录凭证
    └── sync-buf.txt     # 消息同步游标

## 限制

- 仅支持单账号
- 权限审批仍需在终端（Claude Code 的固有限制）
- 语音消息仅提取转写文本
- Session 会过期，需重新扫码
- 需要用户先发消息（context_token 按消息发放）

## License

MIT
