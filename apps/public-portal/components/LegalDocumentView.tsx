import { sanitizePortalHtml } from '@/lib/sanitizePortalHtml'
import type { ResolvedLegalDocument } from '@/lib/legal'

type Props = {
  doc: ResolvedLegalDocument
}

/** Shared legal document body (slug + custom-domain routes). */
export function LegalDocumentView({ doc }: Props) {
  if (!doc.ok) {
    return (
      <p className="text-sm text-muted-foreground">
        Document no disponible ({doc.error ?? 'error'}).
      </p>
    )
  }

  const html = sanitizePortalHtml(doc.body_html ?? '')

  return (
    <>
      <article
        className="prose prose-sm max-w-none"
        dangerouslySetInnerHTML={{ __html: html }}
      />
      <p className="mt-8 text-xs text-muted-foreground">
        Text orientatiu. El responsable del tractament és l’organització titular d’aquest lloc.
      </p>
    </>
  )
}
