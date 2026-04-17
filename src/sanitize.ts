/**
 * reply 工具参数清洗。
 *
 * 模型生成 reply 工具参数时偶尔会"漂移"到 XML 函数调用语法，典型污染：
 *   context_token: "AAR...</context_token><parameter name=\"content\">真正的回复</parameter></invoke>"
 *   content:       ""
 *
 * 这里做的事情：
 *   1. 把 user_id / context_token 截断到第一个 XML 标记前
 *   2. 若 content 为空，尝试从其他字段里的 `<parameter name="content">...</parameter>` 恢复
 *   3. 清理 content 尾部残留的 `</parameter></invoke>`
 *
 * 取代原方案里的 PreToolUse hook `wechat-reply-fix.sh`。
 */

const XML_MARKER = /<\/(?:context_token|user_id)>|<parameter\s+name=|<\/invoke>|<\/parameter>/i;
const TRAILING_XML = /<\/(?:parameter|invoke)>[\s\S]*$|<invoke\b[\s\S]*$/i;

function truncateAtXml(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const m = v.match(XML_MARKER);
  return m && m.index !== undefined ? v.slice(0, m.index) : v;
}

function extractParamFromXml(raw: string, paramName: string): string | undefined {
  const re = new RegExp(`<parameter\\s+name="${paramName}">([\\s\\S]*?)</parameter>`, 'i');
  return raw.match(re)?.[1];
}

export function sanitizeReplyArgs(
  raw: Record<string, unknown> | undefined,
): { args: Record<string, unknown>; fixed: string[] } {
  const input = raw ?? {};
  const origUserId = typeof input.user_id === 'string' ? input.user_id : '';
  const origContext = typeof input.context_token === 'string' ? input.context_token : '';
  const origContent = typeof input.content === 'string' ? input.content : '';
  const out: Record<string, unknown> = { ...input };
  const fixed: string[] = [];

  const cleanUser = truncateAtXml(origUserId);
  if (cleanUser !== undefined && cleanUser !== origUserId) {
    out.user_id = cleanUser;
    fixed.push('user_id');
  }
  const cleanCtx = truncateAtXml(origContext);
  if (cleanCtx !== undefined && cleanCtx !== origContext) {
    out.context_token = cleanCtx;
    fixed.push('context_token');
  }

  if (!origContent.trim()) {
    const recovered =
      extractParamFromXml(origContext, 'content') ??
      extractParamFromXml(origUserId, 'content');
    if (recovered !== undefined) {
      out.content = recovered.replace(TRAILING_XML, '').trim();
      fixed.push('content(recovered)');
    }
  } else {
    const stripped = origContent.replace(TRAILING_XML, '').trimEnd();
    if (stripped !== origContent) {
      out.content = stripped;
      fixed.push('content');
    }
  }

  return { args: out, fixed };
}
