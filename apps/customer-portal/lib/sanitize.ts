import sanitizeHtml from 'sanitize-html'

const ALLOWED = {
  allowedTags: [
    'p', 'br', 'strong', 'em', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'span', 'a',
  ],
  allowedAttributes: {
    a: ['href', 'title', 'rel', 'target'],
    span: ['class'],
  },
  allowedSchemes: ['http', 'https', 'mailto'],
  transformTags: {
    a: sanitizeHtml.simpleTransform('a', { rel: 'noopener noreferrer nofollow', target: '_blank' }),
  },
}

export function sanitizeClientHtml(html: string | null | undefined): string {
  if (!html) return ''
  return sanitizeHtml(html, ALLOWED)
}

export function plainText(html: string | null | undefined): string {
  if (!html) return ''
  return sanitizeHtml(html, { allowedTags: [], allowedAttributes: {} }).trim()
}
