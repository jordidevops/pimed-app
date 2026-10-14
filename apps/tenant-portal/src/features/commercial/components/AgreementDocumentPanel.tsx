import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useTenant } from '@/contexts/TenantContext'
import { useDocument } from '@/features/documents/api/useDocument'
import { supabase } from '@/lib/supabase'
import { DocumentTemplatePreviewPane } from './DocumentTemplatePreviewPane'

type AgreementDocumentPanelProps = {
  renderedDocumentId: string | null
  signedDocumentId: string | null
  fullBodyTemplateId: string | null
  templateName: string | null
}

export function AgreementDocumentPanel({
  renderedDocumentId,
  signedDocumentId,
  fullBodyTemplateId,
  templateName,
}: AgreementDocumentPanelProps) {
  const { t } = useTranslation('projects')
  const { activeTenant } = useTenant()
  const documentId = signedDocumentId ?? renderedDocumentId
  const { data: doc, isLoading: docLoading } = useDocument(
    documentId ?? undefined,
    activeTenant?.id,
  )

  const previewUrlQuery = useQuery({
    queryKey: [
      'agreement-document-preview',
      activeTenant?.id ?? '',
      doc?.version_id ?? '',
      doc?.file_path_or_url ?? '',
    ],
    queryFn: async () => {
      if (!doc?.file_path_or_url) return null
      if (doc.storage_type === 'external_link') return doc.file_path_or_url
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(doc.file_path_or_url, 3600)
      if (error || !data?.signedUrl) throw error ?? new Error('signed_url_missing')
      return data.signedUrl
    },
    enabled: !!doc?.file_path_or_url,
    staleTime: 50 * 60 * 1000,
  })

  const previewUrl = previewUrlQuery.data ?? null
  const isPdf = doc?.mime_type === 'application/pdf' || !!previewUrl?.includes('.pdf')
  const isHtml =
    !!doc?.mime_type?.includes('html') ||
    (!!doc?.file_path_or_url && /\.html?$/i.test(doc.file_path_or_url))

  return (
    <div className="relative flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-border bg-card">
      <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-b border-border px-3 py-2">
        {documentId ? (
          <Button type="button" size="sm" variant="ghost" asChild>
            <Link to={`/documents/${documentId}`}>
              {t('projects.commercial.prepare_agreement_open_pdf', 'Obrir el PDF')}
            </Link>
          </Button>
        ) : null}
        {previewUrl ? (
          <Button type="button" size="sm" variant="ghost" asChild className="ml-auto">
            <a href={previewUrl} target="_blank" rel="noreferrer">
              {t('projects.commercial.share_pdf', 'Descarregar PDF')}
            </a>
          </Button>
        ) : null}
      </div>

      <div
        className={
          previewUrl && isPdf
            ? 'min-h-0 flex-1 overflow-hidden bg-muted/30'
            : 'min-h-0 flex-1 overflow-auto bg-muted/30'
        }
      >
        {docLoading || previewUrlQuery.isLoading ? (
          <div className="p-6 text-sm text-muted-foreground">
            {t('projects.quotes.loading', 'Carregant…')}
          </div>
        ) : previewUrl && isPdf ? (
          <object
            data={previewUrl}
            type="application/pdf"
            className="h-full w-full"
            aria-label={t('projects.commercial.view_tab_document', 'Document')}
          >
            <div className="space-y-2 p-4 text-sm text-muted-foreground">
              <p>
                {t(
                  'projects.commercial.pdf_inline_unavailable',
                  'No es pot previsualitzar el PDF en aquest navegador.',
                )}
              </p>
              <Button type="button" size="sm" variant="outline" asChild>
                <a href={previewUrl} target="_blank" rel="noreferrer">
                  {t('projects.commercial.share_pdf', 'Descarregar PDF')}
                </a>
              </Button>
            </div>
          </object>
        ) : previewUrl && isHtml ? (
          <div className="flex h-full min-h-[36rem] justify-center p-2 sm:p-4">
            <iframe
              title={t('projects.commercial.view_tab_document', 'Document')}
              src={previewUrl}
              className="block h-full min-h-[calc(100dvh-14rem)] w-full max-w-5xl flex-1 rounded-md border border-border/60 bg-white"
            />
          </div>
        ) : fullBodyTemplateId ? (
          <div className="space-y-2 p-3">
            {templateName ? (
              <p className="text-xs text-muted-foreground">
                {t('projects.agreements.template_used', 'Plantilla')}: {templateName}
              </p>
            ) : null}
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.agreements.preview_template_until_pdf',
                'Vista de la plantilla. El PDF de l’acord es genera en preparar o enviar a firmar.',
              )}
            </p>
            <DocumentTemplatePreviewPane templateId={fullBodyTemplateId} />
          </div>
        ) : (
          <div className="space-y-2 p-6 text-sm text-muted-foreground">
            <p>
              {t(
                'projects.agreements.no_pdf_yet',
                'Encara no hi ha PDF: es crea en enviar a firmar.',
              )}
            </p>
            {templateName ? (
              <p>
                {t('projects.agreements.template_used', 'Plantilla')}: {templateName}
              </p>
            ) : null}
          </div>
        )}
      </div>
    </div>
  )
}
