# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Fork of [paceaitian/cc-wechat](https://github.com/paceaitian/cc-wechat) (MIT). The upstream git remote is `upstream`; `origin` points at the `dranixj/claude-weixin-channel` fork. This fork adds a set of lifecycle hooks (`hooks/wechat-*.sh`) and a built-in `sanitizeReplyArgs()` in the MCP server.

Published to npm as `claude-weixin-channel`. The `packages/claude-weixin-channel-patch` subdirectory is a standalone zero-dependency patch package, fork of upstream `cc-channel-patch`.

## Commands

```bash
npm run build        # tsc → dist/
npm run dev          # tsc --watch
```

There is no lint, no test suite, and no single-test runner. `npm run prepublishOnly` triggers `build` before publishing.

Dev smoke-test against a real Claude Code install:

```bash
npm run build
node dist/cli.js install         # register MCP + scan-to-login
node dist/cli.js login           # re-login only
node dist/cli.js install-hooks   # merge hooks into ~/.claude/settings.json
claude --dangerously-load-development-channels server:wechat-channel
```

## Architecture

### Runtime topology

```
WeChat → Tencent iLink Bot API → MCP server (long-poll getupdates)
                                     ↓
                                Claude Code (stdio)
                                     ↓
                                reply tool → sendmessage → WeChat
```

The MCP server is a single stdio process (`src/server.ts`). It exposes two tools — `login` and `reply` — and drives a long-poll loop against `getupdates` (35s timeout). Each inbound WeChat message is delivered to Claude Code as a `<channel source="wechat-channel" user_id=... context_token=... message_id=...>` tag; Claude replies by calling the `reply` tool with `user_id` + `context_token` echoed back.

### Module boundaries (`src/`)

- `server.ts` — MCP entry + long-poll orchestrator + session-expiry retry logic. `sanitizeReplyArgs()` (from `sanitize.ts`) strips XML/tag pollution from Claude's `reply` calls; this is the in-fork replacement for the upstream `wechat-reply-fix.sh` PreToolUse hook.
- `cli.ts` — `install` / `login` / `patch` / `install-hooks` commands. When invoked with no args on a non-TTY stdin, it transparently delegates to `server.ts` (this is how the MCP `command: npx … claude-weixin-channel` registration works).
- `ilink-api.ts` — 7 iLink HTTP endpoints. `getupdates` is the long-poll; `sendmessage`, `sendtyping`, `getconfig`, `getuploadurl`, `get_bot_qrcode`, `get_qrcode_status`.
- `auth.ts` — QR-code login flow, both terminal (`loginTerminal`) and in-Claude (`loginBrowser`).
- `store.ts` — credentials + sync cursor under `~/.claude/channels/wechat/<profile>/` (`account.json`, `sync-buf.txt`). Profile is selected via `WECHAT_PROFILE` env var; unset → `default`.
- `cdn.ts` — media upload/download via Tencent's encrypted CDN (AES-keyed URLs).
- `text-utils.ts` — `chunkText()` for splitting long replies.
- `hooks.ts` — merges/un-merges the four hook entries into `~/.claude/settings.json`, backing up to `.bak`.
- `patch.ts` — regex-based patcher that enables Claude Code's gated `Channels` feature across native/npm installs on Win/macOS/Linux/WSL. `unpatch` restores.
- `sanitize.ts` — `sanitizeReplyArgs()`; see "Reply sanitization" below.
- `proxy.ts` — must be imported first in both `server.ts` and `cli.ts` to wire HTTP(S) proxy env vars.

### Hooks (`hooks/*.sh`)

Four bash hooks, shipped in the npm tarball and installed into `~/.claude/hooks/` by `install-hooks`:

| Script | Event | Responsibility |
|--------|-------|----------------|
| `wechat-ack.sh` | `UserPromptSubmit` | Send "收到，处理中..."; parse slash commands (`/new`, `/clear`, `/mode`, `/stream`, `/progress`, `/session-status`, `/help`, etc.); persist session state |
| `wechat-progress.sh` | `PostToolUse` | Push tool-progress notifications to WeChat (off by default) |
| `wechat-stream.sh` | `PostChunk` | Forward Claude streaming chunks to WeChat (on by default) |
| `wechat-stop-notify.sh` | `Stop` | If no `.replied` marker exists, notify WeChat that processing aborted (quota, crash, etc.) |
| `wechat-reply-sent.sh` | `PostToolUse` (reply only) | Touch the `.replied` marker that `stop-notify` keys off |

Per-session state lives in `$CLAUDE_WEIXIN_HOOKS_DIR` (default `~/.cache/claude-weixin-channel/hooks/`) as `${session_id}.session.json` — carries `user_id`, `context_token`, `mode`, `mode_ctx`, `stream_notify`, `progress_notify` across `UserPromptSubmit` → … → `Stop`.

Hooks depend on `jq`, `curl`, `python3` (the latter only for multi-line `<channel>` body extraction in `wechat-ack.sh`).

### Reply sanitization

Claude sometimes wraps its `reply` arguments in XML-ish tags that would otherwise be rendered literally in WeChat. `sanitizeReplyArgs()` runs inside the MCP `CallToolRequest` handler before `sendmessage`. **Do not** reintroduce a `wechat-reply-fix.sh` PreToolUse hook — it's been intentionally absorbed into the server because this fork controls the source. The design note at the bottom of `hooks/README.md` explains the trade-off.

### Multi-account

`WECHAT_PROFILE` env var selects a namespace under `~/.claude/channels/wechat/`. A project-level `.mcp.json` entry named `wechat-channel` overrides the user-level registration, so per-repo bindings work by re-declaring the server with a different `WECHAT_PROFILE`. New profiles require a fresh QR login (`WECHAT_PROFILE=work npx claude-weixin-channel login`).

## Conventions

- TypeScript, ESM (`"type": "module"`), Node ≥ 22. All intra-module imports use `.js` extensions even for `.ts` sources — required for ESM resolution post-build.
- No test framework is wired up; validation is manual against a live WeChat account.
- Commit style: Conventional Commits (`feat:`, `fix:`, `chore(release):`, `refactor(hooks):`, …). The `chore(release): vX.Y.Z` commit is the cut-point for npm publishes.
