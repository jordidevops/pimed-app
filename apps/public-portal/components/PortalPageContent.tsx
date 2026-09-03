import type { JSX } from 'react'
import type { PublicSite, PublicPage } from '@/lib/portal'
import { sanitizePortalHtml } from '@/lib/sanitizePortalHtml'

interface Props {
  site: PublicSite
  page: PublicPage | null
  localizedTitle?: string | null
  locale?: string
}

type ContentBlock = {
  type: 'paragraph' | 'heading' | 'image' | 'html'
  content?: string
  src?: string
  alt?: string
  level?: number
}

function renderBlock(block: ContentBlock, idx: number) {
  switch (block.type) {
    case 'heading': {
      const Tag = (`h${block.level ?? 2}`) as keyof JSX.IntrinsicElements
      return (
        <Tag key={idx} className="font-bold text-foreground">
          {block.content}
        </Tag>
      )
    }
    case 'image':
      return block.src ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img key={idx} src={block.src} alt={block.alt ?? ''} className="max-w-full rounded-lg" />
      ) : null
    case 'html':
      return (
        <div
          key={idx}
          dangerouslySetInnerHTML={{ __html: sanitizePortalHtml(block.content ?? '') }}
        />
      )
    default:
      return (
        <p key={idx} className="text-foreground">
          {block.content}
        </p>
      )
  }
}

function renderContent(content: unknown) {
  if (!content) return null

  // Suporta format { blocks: ContentBlock[] }
  if (typeof content === 'object' && content !== null && 'blocks' in content) {
    const blocks = (content as { blocks: ContentBlock[] }).blocks
    return <>{blocks.map((b, i) => renderBlock(b, i))}</>
  }

  // Suporta format { html: string }
  if (typeof content === 'object' && content !== null && 'html' in content) {
    const html = (content as { html: string }).html
    return (
      <div
        dangerouslySetInnerHTML={{ __html: sanitizePortalHtml(html) }}
      />
    )
  }

  // Fallback: renderitza com a text pla
  if (typeof content === 'string') {
    return <p className="text-foreground">{content}</p>
  }

  return null
}

/**
 * Renderitzador de contingut del portal públic.
 * Suporta tres formats de contingut JSON:
 * - { blocks: ContentBlock[] } — format de blocs
 * - { html: string }           — HTML directe
 * - string                     — text pla (fallback)
 */
export function PortalPageContent({ site, page, localizedTitle, locale }: Props) {
  const title = localizedTitle ?? page?.title ?? site.name

  // Resolució de contingut: usa la traducció del locale si existeix, fallback al contingut base
  const translations = (page?.translations as Record<string, { content?: unknown }> | null) ?? {}
  const localizedContent = locale ? translations[locale]?.content : undefined
  const content = localizedContent ?? page?.content ?? site.content

  return (
    <article className="mx-auto max-w-4xl px-4 py-12">
      <h1 className="mb-8 text-3xl font-bold text-foreground">{title}</h1>
      <div className="prose prose-neutral max-w-none space-y-4">
        {renderContent(content)}
      </div>
    </article>
  )
}
