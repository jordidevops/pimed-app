import type { ReactNode } from 'react'

const MENTION_TOKEN_RE = /\[\[@([0-9a-f-]{36})\|([^\]]+)\]\]/gi

/** Converteix tokens [[@uuid|Nom]] en @Nom sense mostrar l'UUID. */
export function renderMentionContent(content: string | null): ReactNode {
  if (!content) return null

  const parts: ReactNode[] = []
  let lastIndex = 0
  const re = new RegExp(MENTION_TOKEN_RE.source, MENTION_TOKEN_RE.flags)
  let match: RegExpExecArray | null

  while ((match = re.exec(content)) !== null) {
    if (match.index > lastIndex) {
      parts.push(<span key={`t-${lastIndex}`}>{content.slice(lastIndex, match.index)}</span>)
    }
    parts.push(
      <span key={`m-${match.index}`} className="text-primary font-medium">
        @{match[2]}
      </span>,
    )
    lastIndex = re.lastIndex
  }

  if (lastIndex < content.length) {
    parts.push(<span key={`t-${lastIndex}`}>{content.slice(lastIndex)}</span>)
  }

  return parts.length > 0 ? parts : content
}
