import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { DocxPreviewPane } from '@/features/signing/components/DocxPreviewModal'
import { getCommercialFullBodyLocale } from '../api/commercialFlowService'
import {
  buildIssuedCommercialPreview,
  type IssuedCommercialPreview,
} from '../utils/buildIssuedCommercialHtml'
import type { CommercialDocumentDetail } from '../utils/commercialDocumentModel'

function withPreviewPadding(html: string): string {
  const style = '<style>body{padding:28px !important;}</style>'
  if (html.includes('</head>')) return html.replace('</head>', `${style}</head>`)
  return `<head>${style}</head>${html}`
}

type Props = {
  doc: CommercialDocumentDetail
  templateId: string
}

export function LiveCommercialPreview({ doc, templateId }: Props) {
  const { t } = useTranslation('projects')
  const [preview, setPreview] = useState<IssuedCommercialPreview | null>(null)
  const [docxPath, setDocxPath] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    const overlaid: CommercialDocumentDetail = {
      ...doc,
      full_body_template_id: templateId || null,
    }
    void (async () => {
      try {
        const next = await buildIssuedCommercialPreview(overlaid)
        if (cancelled) return
        setPreview(next)
        if (next.kind === 'docx' && templateId) {
          const locale = await getCommercialFullBodyLocale({
            tenantId: doc.tenant_id,
            templateId,
            locale: doc.locale || 'ca',
          })
          if (!cancelled) setDocxPath(locale?.storage_path ?? null)
        } else if (!cancelled) {
          setDocxPath(null)
        }
      } catch {
        if (!cancelled) {
          setPreview(null)
          setDocxPath(null)
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [doc, templateId])

  if (loading) {
    return (
      <p className="rounded-lg border border-border px-3 py-4 text-xs text-muted-foreground">
        {t('projects.commercial.template_preview_loading', 'Carregant vista prèvia…')}
      </p>
    )
  }

  if (preview?.kind === 'docx') {
    return (
      <div className="space-y-2">
        <p className="text-xs text-muted-foreground">
          {t(
            'projects.orphan.docx_preview_note',
            'Vista prèvia amb les dades d’aquest pressupost. El PDF definitiu es genera en emetre.',
          )}
        </p>
        {docxPath ? (
          <div className="flex h-[min(70dvh,40rem)] min-h-[28rem] flex-col">
            <DocxPreviewPane
              storagePath={docxPath}
              bucket="document-templates"
              previewValues={preview.previewValues}
              showZoomControls
              initialZoom="fit"
              className="min-h-0 flex-1"
            />
          </div>
        ) : (
          <p className="rounded-lg border border-border bg-muted/30 px-3 py-4 text-xs text-muted-foreground">
            {t(
              'projects.commercial.template_preview_docx_missing',
              'Aquesta plantilla DOCX no té fitxer desat; no es pot mostrar la vista prèvia.',
            )}
          </p>
        )}
      </div>
    )
  }

  if (preview?.kind === 'html') {
    return (
      <iframe
        title={t('projects.commercial.view_html_draft', 'Esborrany HTML')}
        srcDoc={withPreviewPadding(preview.html)}
        className="h-[min(70dvh,40rem)] min-h-[28rem] w-full rounded-lg border border-border bg-white"
      />
    )
  }

  return (
    <p className="rounded-lg border border-dashed border-border px-3 py-4 text-xs text-muted-foreground">
      {t(
        'projects.orphan.preview_unavailable',
        'No s’ha pogut muntar la vista prèvia amb les dades d’aquest pressupost.',
      )}
    </p>
  )
}
