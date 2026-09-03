import { Liquid } from 'liquidjs'

const _previewEngine = new Liquid({ strictVariables: false, strictFilters: false })

export interface PreviewBlock {
  id?: string | null
  name?: string | null
  block_type?: string | null
  format?: string | null
  content?: string | null
}

export interface PreviewRenderOptions {
  blockMapping?: Record<string, string> | null
  blocks?: PreviewBlock[] | null
  tenant?: Record<string, unknown> | null
}

function sanitizeHtml(html: string): string {
  return html
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, '')
    .replace(/<script\b[^>]*>/gi, '')
    .replace(/\son\w+\s*=\s*"[^"]*"/gi, '')
    .replace(/\son\w+\s*=\s*'[^']*'/gi, '')
    .replace(/\son\w+\s*=\s*[^\s>]+/gi, '')
    .replace(/\b(href|src)\s*=\s*"javascript:[^"]*"/gi, '$1="#"')
    .replace(/\b(href|src)\s*=\s*'javascript:[^']*'/gi, "$1='#'")
    .replace(/\b(href|src)\s*=\s*javascript:[^\s>]+/gi, '$1="#"')
}

export function buildPreviewHtml(
  html: string,
  values: Record<string, unknown>,
  options: PreviewRenderOptions = {},
): string {
  const ctx: Record<string, unknown> = {
    globals: {
      today: new Date().toISOString().split('T')[0],
      date: new Date().toISOString().split('T')[0],
      year: String(new Date().getFullYear()),
      now: new Date().toISOString(),
    },
    input: values,
    ...values,
  }

  if (options.tenant && typeof options.tenant === 'object') {
    ctx.tenant = options.tenant
  }

  const mappingEntries = Object.entries(options.blockMapping ?? {})
  const blockMap = new Map((options.blocks ?? []).map(block => [block.id ?? '', block]))

  for (const [mappingKey, blockId] of mappingEntries) {
    const block = blockMap.get(blockId)
    if (!block || !block.content) continue

    let rendered = block.content
    try {
      rendered = _previewEngine.parseAndRenderSync(block.content, ctx)
    } catch {
      rendered = block.content
    }

    switch (block.block_type) {
      case 'DOCUMENT_HEADER':
        ctx.document_header = rendered
        break
      case 'DOCUMENT_FOOTER':
        ctx.document_footer = rendered
        break
      case 'CUSTOM': {
        const slug = mappingKey.toLowerCase().replace(/[^a-z0-9_]/g, '_')
        ctx[`custom_block_${slug}`] = rendered
        break
      }
      default:
        break
    }
  }

  let renderedHtml = html
  try {
    renderedHtml = _previewEngine.parseAndRenderSync(html, ctx)
  } catch {
    renderedHtml = html
  }

  const safeHtml = sanitizeHtml(renderedHtml)

  return `<!DOCTYPE html><html lang="ca"><head><meta charset="UTF-8"><style>body{font-family:system-ui,sans-serif;font-size:14px;line-height:1.6;color:#111;padding:24px 32px;max-width:860px;margin:0 auto}h1,h2,h3{margin-top:1.2em}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:6px 10px}</style></head><body>${safeHtml}</body></html>`
}
