import { sanitizePortalHtml } from './sanitizePortalHtml'

/** True if the string looks like HTML markup (not plain text). */
export function looksLikeHtml(value: string): boolean {
  return /<\/?[a-z][\s\S]*>/i.test(value)
}

/** Strip tags for meta / list excerpts. */
export function stripHtml(value: string): string {
  return value
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/\s+/g, ' ')
    .trim()
}

function escapeText(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

/**
 * Normalize posting description for safe public render.
 * Plain-text legacy rows keep newlines; HTML is sanitized.
 */
export function postingDescriptionHtml(description: string | null | undefined): string | null {
  if (!description?.trim()) return null
  if (looksLikeHtml(description)) {
    const clean = sanitizePortalHtml(description)
    return clean.trim() ? clean : null
  }
  const paragraphs = description
    .split(/\n{2,}/)
    .map((p) => `<p>${escapeText(p).replace(/\n/g, '<br>')}</p>`)
    .join('')
  return sanitizePortalHtml(paragraphs)
}
