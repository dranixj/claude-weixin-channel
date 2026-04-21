/**
 * Hook 安装/卸载 — 将 hooks/*.sh 注入 ~/.claude/settings.json
 */

import fs from 'node:fs';
import path from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

// ─── hook 规格 ────────────────────────────────────────

interface HookEntry {
  type: 'command';
  command: string;
  timeout?: number;
}
interface HookMatcher {
  matcher: string;
  hooks: HookEntry[];
}
type HookEvent = 'UserPromptSubmit' | 'PreToolUse' | 'PostToolUse' | 'Stop';

interface HookSpec {
  script: string;
  event: HookEvent;
  matcher: string;
  timeout: number;
}

const HOOK_SPECS: HookSpec[] = [
  { script: 'wechat-bg-guard.sh',     event: 'PreToolUse',       matcher: 'Bash',                         timeout: 5  },
  { script: 'wechat-ack.sh',          event: 'UserPromptSubmit', matcher: '*',                            timeout: 10 },
  { script: 'wechat-reply-sent.sh',   event: 'PostToolUse',      matcher: 'mcp__wechat-channel__reply',   timeout: 5  },
  { script: 'wechat-progress.sh',     event: 'PostToolUse',      matcher: '*',                            timeout: 5  },
  { script: 'wechat-stop-notify.sh',  event: 'Stop',             matcher: '*',                            timeout: 10 },
];

// 非 hook 本体但需随包复制到 ~/.claude/hooks/ 的辅助脚本（由其他 hook 启动）
const SATELLITE_FILES: string[] = [
  'wechat-stream.sh',
];

// ─── 路径解析 ─────────────────────────────────────────

/** 定位 npm 包内随源码一起分发的 hooks/ 目录 */
function resolveSourceHooksDir(): string {
  const here = fileURLToPath(import.meta.url);
  // 已构建时: <pkg>/dist/hooks.js  →  <pkg>/hooks/
  // 源码运行时: <pkg>/src/hooks.ts →  <pkg>/hooks/
  return path.resolve(path.dirname(here), '..', 'hooks');
}

function settingsPath(): string {
  return path.join(homedir(), '.claude', 'settings.json');
}

function installDir(): string {
  return path.join(homedir(), '.claude', 'hooks');
}

// ─── settings.json 合并 ──────────────────────────────

type SettingsShape = {
  hooks?: Partial<Record<HookEvent, HookMatcher[]>>;
  [k: string]: unknown;
};

function readSettings(): SettingsShape {
  const p = settingsPath();
  if (!fs.existsSync(p)) return {};
  try {
    return JSON.parse(fs.readFileSync(p, 'utf-8')) as SettingsShape;
  } catch (err) {
    throw new Error(`无法解析 ${p}: ${(err as Error).message}`);
  }
}

function writeSettings(s: SettingsShape): void {
  const p = settingsPath();
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n', 'utf-8');
}

function backupSettings(): string | null {
  const p = settingsPath();
  if (!fs.existsSync(p)) return null;
  const bak = p + '.bak';
  fs.copyFileSync(p, bak);
  return bak;
}

/** 判断 hook 条目是否由本项目管理 */
function isOurs(entry: HookEntry, scripts: Set<string>): boolean {
  const cmd = entry.command ?? '';
  return [...scripts].some((s) => cmd.endsWith(s) || cmd.includes(`/hooks/${s}`));
}

function mergeEvent(
  existing: HookMatcher[] | undefined,
  spec: HookSpec,
  commandPath: string,
  ourScripts: Set<string>,
): HookMatcher[] {
  const list = existing ? existing.map((m) => ({ ...m, hooks: [...m.hooks] })) : [];

  // 先剔除任何旧的、由我们管理的条目（避免重复，便于升级）
  for (const m of list) {
    m.hooks = m.hooks.filter((h) => !isOurs(h, ourScripts));
  }

  // 找到（或新建）匹配 matcher 的桶
  let bucket = list.find((m) => m.matcher === spec.matcher);
  if (!bucket) {
    bucket = { matcher: spec.matcher, hooks: [] };
    list.push(bucket);
  }
  bucket.hooks.push({ type: 'command', command: commandPath, timeout: spec.timeout });

  // 清掉空桶
  return list.filter((m) => m.hooks.length > 0);
}

// ─── install ─────────────────────────────────────────

export function installHooks(): void {
  const src = resolveSourceHooksDir();
  const dst = installDir();
  if (!fs.existsSync(src)) {
    throw new Error(`找不到源 hooks 目录: ${src}`);
  }
  fs.mkdirSync(dst, { recursive: true });

  const scriptNames = HOOK_SPECS.map((s) => s.script);
  const ourScripts = new Set(scriptNames);
  const allFiles = [...scriptNames, ...SATELLITE_FILES];

  console.log('\n🪝 claude-weixin-channel — 安装 hooks\n');
  for (const name of allFiles) {
    const from = path.join(src, name);
    const to = path.join(dst, name);
    if (!fs.existsSync(from)) throw new Error(`缺失脚本: ${from}`);
    fs.copyFileSync(from, to);
    try { fs.chmodSync(to, 0o755); } catch { /* ignore on windows */ }
    console.log(`  ✅ 复制 ${name} → ${to}`);
  }

  const bak = backupSettings();
  if (bak) console.log(`\n  📦 已备份 settings.json → ${bak}`);

  const settings = readSettings();
  settings.hooks = settings.hooks ?? {};
  for (const spec of HOOK_SPECS) {
    const commandPath = path.join('$HOME', '.claude', 'hooks', spec.script);
    settings.hooks[spec.event] = mergeEvent(
      settings.hooks[spec.event],
      spec,
      commandPath,
      ourScripts,
    );
    console.log(`  ✅ 合并 ${spec.event} / ${spec.matcher} → ${spec.script}`);
  }
  writeSettings(settings);

  console.log(`\n  ✨ 安装完成。设置文件: ${settingsPath()}\n`);
  console.log('  日志目录: $HOME/.cache/claude-weixin-channel/hooks/\n');
}

// ─── uninstall ───────────────────────────────────────

export function uninstallHooks(): void {
  const ourScripts = new Set(HOOK_SPECS.map((s) => s.script));

  console.log('\n🪝 claude-weixin-channel — 卸载 hooks\n');

  const bak = backupSettings();
  if (bak) console.log(`  📦 已备份 settings.json → ${bak}`);

  const settings = readSettings();
  if (!settings.hooks) {
    console.log('  ℹ️  settings.json 未配置 hooks，无事可做。');
    return;
  }

  let removed = 0;
  for (const ev of Object.keys(settings.hooks) as HookEvent[]) {
    const buckets = settings.hooks[ev];
    if (!buckets) continue;
    for (const m of buckets) {
      const before = m.hooks.length;
      m.hooks = m.hooks.filter((h) => !isOurs(h, ourScripts));
      removed += before - m.hooks.length;
    }
    settings.hooks[ev] = buckets.filter((m) => m.hooks.length > 0);
    if (settings.hooks[ev]!.length === 0) delete settings.hooks[ev];
  }
  if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  writeSettings(settings);

  console.log(`  ✅ 已从 settings.json 移除 ${removed} 条 hook 条目`);
  console.log(`  ℹ️  脚本文件保留在 ${installDir()}（可手动删除）\n`);
}
