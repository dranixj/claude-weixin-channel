# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与
[Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.3.1] - 2026-04-20

### 修复

- **wechat-stream.sh**：流超时从「绝对 600s」改为「空闲 600s」——每次成功推送 chunk 后 touch `.stream.heartbeat`，超时检查比较 heartbeat mtime，有内容输出即续约（fix #2）

## [0.3.0] - 2026-04-18

### 新增

- **测试体系**：新增 `test/` 目录，基于 Node 内置 `node:test`，覆盖 `sanitize.ts`（reply 参数清洗）和 `text-utils.ts`（Markdown 清理 / 分段）共 12 个用例
- **Lint**：引入 ESLint 9 + `@typescript-eslint`，flat config (`eslint.config.js`)
- **npm scripts**：新增 `lint` / `typecheck` / `test` 三个命令，`test` 会先走 `tsconfig.test.json` 编译再跑 `node --test`
- **CLAUDE.md**：项目根目录新增 Claude Code 引导文件，说明架构、模块边界、hook 生命周期和约定
- **README — 安全说明**：
  - 启动命令补上 `--dangerously-skip-permissions`，并新增整段关于"为什么必须 yolo 模式"的说明
  - 新增「关于斜杠命令的控制台告警」小节：解释 `/mode`、`/clear` 等由 hook 拦截，Claude Code 控制台的 `Unknown command` 为预期行为
- **README — 关于作者**：新增引流段落，指向 [dranixj.com](https://dranixj.com)
- **路线图**：新增 **Hook 层安全校验（PreToolUse）** 条目，计划在 yolo 模式下拦截 `rm -rf /`、`curl … | sh` 等高危操作

### 变更

- **MCP server 迁移**：`src/server.ts` 从已弃用的 `Server` 类迁移到 `McpServer`
  - 工具注册改用 `registerTool(name, { description, inputSchema: zod shape }, handler)`
  - 自定义通知改为 `server.server.notification(...)`
  - 消除 TypeScript 的 `'Server' is deprecated` 告警
- **新增运行时依赖**：`zod ^4.0.0`（MCP SDK 新 API 要求）
- **新增 devDependencies**：`eslint`、`@typescript-eslint/parser`、`@typescript-eslint/eslint-plugin`
- **.gitignore**：新增 `dist-test/`

### 移除

- 路线图删除"与上游 `cc-wechat` 的 upstream 跟踪合并策略"条目

---

## [0.2.0] - 2026-04

### 新增

- **Session 状态持久化**：`wechat-ack.sh` 写入 `${session_id}.session.json`，跨 hook 共享 `user_id` / `context_token` / `mode` / `stream_notify` / `progress_notify`
- **斜杠命令**：`/new`、`/clear`、`/mode <name>`、`/compact`、`/think`、`/stream on|off`、`/progress on|off`、`/session-status`、`/help`
- **流式转发**（`wechat-stream.sh` on `PostChunk`）：Claude 的流式输出实时推送到微信，默认开启
- **工具进度通知**（`wechat-progress.sh` on `PostToolUse`）：工具调用进度可选推送，默认关闭，由 `/progress on` 开启
- **Markdown 保留**：`reply` 默认保留 Markdown 格式分段发送（不再强制 `stripMarkdown`）

### 变更

- `wechat-ack.sh` / `wechat-stop-notify.sh` 增强：改进错误处理和会话状态联动

---

## [0.1.0] - fork 首发

### 新增

- Fork 自 [paceaitian/cc-wechat](https://github.com/paceaitian/cc-wechat)，重命名为 `claude-weixin-channel`
- **`sanitizeReplyArgs()`**：内置 reply 参数 XML 污染清洗（取代上游 `wechat-reply-fix.sh` PreToolUse hook）
- **`install-hooks` / `uninstall-hooks` CLI**：一键安装/卸载四个生命周期 hook 脚本到 `~/.claude/settings.json`
- **四个 hook 脚本**：`wechat-ack.sh`、`wechat-progress.sh`、`wechat-stream.sh`、`wechat-stop-notify.sh`
- **多账号 profile 支持**：`WECHAT_PROFILE` 环境变量区分账号命名空间
- **Patch 模块**：正则匹配 + 多变体函数名，适配 Windows / macOS / Linux / WSL 下的 native 与 npm 安装
- **macOS 重签名**：patch 后自动 `codesign` 规避 Gatekeeper
- **HTTPS_PROXY 支持**：WSL2 / 企业网络下 Node.js fetch 走代理
- **子包**：`packages/claude-weixin-channel-patch`（fork 自上游 `cc-channel-patch`）
- **引用回复**：`reply` 工具新增 `reply_to_message_id` 参数

[0.3.0]: https://github.com/dranixj/claude-weixin-channel/releases/tag/v0.3.0
[0.2.0]: https://github.com/dranixj/claude-weixin-channel/releases/tag/v0.2.0
[0.1.0]: https://github.com/dranixj/claude-weixin-channel/releases/tag/v0.1.0
