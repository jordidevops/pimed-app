import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getCommercialDocumentDetail,
  recordCommercialDocumentSent,
} from '../api/commercialFlowService'
import { useCommercialPdf } from '../hooks/useCommercialPdf'
import { useCommercialDocumentSigningHub } from '../api/useCommercialSigningHub'
import {
  commercialSignedPdfDocumentId,
} from '../utils/commercialSigningHub'
import type { CommercialDocumentDetail } from '../utils/commercialDocumentModel'
import { commercialFilename } from '../utils/commercialDocumentModel'
import {
  downloadCommercialDocumentHtml,
  downloadCommercialDocumentPdfFromUrl,
  printCommercialDocument,
} from '../utils/commercialDocumentPrint'
import { ISSUED_COMMERCIAL_DOCX_UNAVAILABLE } from '../utils/buildIssuedCommercialHtml'
import {
  buildCommercialMailto,
  buildCommercialWhatsAppUrl,
  copyCommercialShareText,
  generateCommercialShareQrDataUrl,
  tryNativeCommercialShare,
} from '../utils/commercialShare'

interface CommercialDocumentShareSheetProps {
  documentId: string
  open: boolean
  onClose: () => void
}

export function CommercialDocumentShareSheet({
  documentId,
  open,
  onClose,
}: CommercialDocumentShareSheetProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const [doc, setDoc] = useState<CommercialDocumentDetail | null>(null)
  const [loading, setLoading] = useState(false)
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null)
  const [busyChannel, setBusyChannel] = useState<string | null>(null)
  const pdf = useCommercialPdf({
    documentId,
    tenantId: doc?.tenant_id ?? null,
    enabled: open && !!doc,
    initialRenderedDocumentId: doc?.rendered_document_id,
    initialPdfJobId: doc?.pdf_job_id,
  })
  const { data: signingHub } = useCommercialDocumentSigningHub(open ? documentId : null)
  const signedPdfId = commercialSignedPdfDocumentId(signingHub)

  useEffect(() => {
    if (!open) return
    let cancelled = false
    setLoading(true)
    setQrDataUrl(null)
    void (async () => {
      try {
        const detail = await getCommercialDocumentDetail(documentId)
        if (cancelled) return
        setDoc(detail)
        const qr = await generateCommercialShareQrDataUrl(detail)
        if (!cancelled) setQrDataUrl(qr)
      } catch (err) {
        if (!cancelled) {
          toast({
            variant: 'destructive',
            title: t('projects.commercial.share_load_failed', "No s'ha pogut carregar el document"),
            description: err instanceof Error ? err.message : undefined,
          })
          onClose()
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- load once per open/documentId
  }, [documentId, open])

  if (!open) return null

  async function markSent(channel: string) {
    if (!doc) return
    try {
      await recordCommercialDocumentSent({
        documentId: doc.id,
        channel,
        device: typeof navigator !== 'undefined' ? navigator.userAgent.slice(0, 180) : null,
      })
    } catch {
      // Share already succeeded; audit failure must not block retry UX.
    }
  }

  async function runChannel(channel: string, action: () => Promise<void> | void) {
    setBusyChannel(channel)
    try {
      await action()
      await markSent(channel)
      toast({
        title: t('projects.commercial.share_ok', 'Document preparat per enviar'),
      })
    } catch (err) {
      const isDocx =
        err instanceof Error && err.message === ISSUED_COMMERCIAL_DOCX_UNAVAILABLE
      toast({
        variant: 'destructive',
        title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
        description: isDocx
          ? t(
              'projects.commercial.view_docx_use_pdf',
              'Aquesta plantilla és DOCX: el PDF és la còpia fidel. L’HTML per defecte no s’hi mostra.',
            )
          : err instanceof Error
            ? err.message
            : undefined,
      })
    } finally {
      setBusyChannel(null)
    }
  }

  const pdfReady = pdf.status === 'ready' && !!pdf.downloadUrl

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto space-y-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-foreground">
              {t('projects.commercial.share_title', 'Enviar document')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.commercial.share_help',
                'WhatsApp, correu, compartició nativa, PDF i QR. Si falla l’enviament, el document continua emès.',
              )}
            </p>
          </div>
          <Button type="button" variant="ghost" size="sm" onClick={onClose}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
        </div>

        {loading || !doc ? (
          <p className="text-sm text-muted-foreground">
            {t('projects.commercial.share_loading', 'Carregant…')}
          </p>
        ) : (
          <>
            <p className="text-sm font-medium text-foreground">
              {doc.doc_number ?? '—'} · {doc.doc_type} · {Number(doc.total).toFixed(2)} €
            </p>

            {pdf.status === 'loading' ? (
              <p className="text-xs text-muted-foreground">
                {t('projects.commercial.pdf_generating', 'Generant PDF…')}
              </p>
            ) : null}
            {pdf.status === 'pending' ? (
              <p className="text-xs text-muted-foreground">
                {t(
                  'projects.commercial.pdf_pending',
                  'El PDF s’està generant. Mentrestant pots enviar l’HTML.',
                )}
              </p>
            ) : null}
            {pdf.status === 'offline' || pdf.status === 'error' ? (
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-xs text-muted-foreground">
                  {t(
                    'projects.commercial.pdf_html_fallback',
                    'PDF no disponible ara. Pots imprimir o descarregar l’HTML.',
                  )}
                </p>
                <Button type="button" size="sm" variant="ghost" onClick={() => void pdf.refresh()}>
                  {t('projects.commercial.pdf_retry', 'Reintentar PDF')}
                </Button>
              </div>
            ) : null}

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <Button
                type="button"
                disabled={!!busyChannel}
                onClick={() =>
                  void runChannel('whatsapp', () => {
                    window.open(buildCommercialWhatsAppUrl(doc), '_blank', 'noopener,noreferrer')
                  })
                }
              >
                {t('projects.commercial.share_whatsapp', 'WhatsApp')}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!!busyChannel}
                onClick={() =>
                  void runChannel('email', () => {
                    window.location.href = buildCommercialMailto(doc)
                  })
                }
              >
                {t('projects.commercial.share_email', 'Correu')}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!!busyChannel}
                onClick={() =>
                  void (async () => {
                    setBusyChannel('native')
                    try {
                      const result = await tryNativeCommercialShare(
                        doc,
                        pdfReady ? pdf.downloadUrl : null,
                      )
                      if (result === 'cancelled') return
                      if (result === 'unsupported') {
                        throw new Error(
                          t(
                            'projects.commercial.share_native_unsupported',
                            'Aquest dispositiu no admet compartició nativa',
                          ),
                        )
                      }
                      await markSent('native')
                      toast({
                        title: t('projects.commercial.share_ok', 'Document preparat per enviar'),
                      })
                    } catch (err) {
                      toast({
                        variant: 'destructive',
                        title: t(
                          'projects.commercial.share_failed',
                          'Enviament fallit · Reintentar',
                        ),
                        description: err instanceof Error ? err.message : undefined,
                      })
                    } finally {
                      setBusyChannel(null)
                    }
                  })()
                }
              >
                {t('projects.commercial.share_native', 'Compartir')}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!!busyChannel}
                onClick={() =>
                  void runChannel('copy', async () => {
                    await copyCommercialShareText(doc)
                  })
                }
              >
                {t('projects.commercial.share_copy', 'Copiar text')}
              </Button>
              <Button
                type="button"
                disabled={!!busyChannel || !pdfReady}
                onClick={() =>
                  void runChannel('pdf', () => {
                    downloadCommercialDocumentPdfFromUrl(
                      pdf.downloadUrl!,
                      commercialFilename(doc, 'pdf'),
                    )
                  })
                }
              >
                {pdf.status === 'pending'
                  ? t('projects.commercial.pdf_generating', 'Generant PDF…')
                  : t('projects.commercial.share_pdf', 'Descarregar PDF')}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!!busyChannel}
                onClick={() =>
                  void runChannel('print', () => printCommercialDocument(doc))
                }
              >
                {t('projects.commercial.share_print', 'Imprimir HTML')}
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!!busyChannel}
                onClick={() =>
                  void runChannel('download', () => downloadCommercialDocumentHtml(doc))
                }
              >
                {t('projects.commercial.share_download', 'Descarregar HTML')}
              </Button>
              {pdf.renderedDocumentId ? (
                <Button type="button" variant="outline" asChild>
                  <Link to={`/documents/${pdf.renderedDocumentId}`}>
                    {t('projects.commercial.open_dms', 'Obrir al DMS')}
                  </Link>
                </Button>
              ) : null}
              {signedPdfId && signedPdfId !== pdf.renderedDocumentId ? (
                <Button type="button" variant="outline" asChild>
                  <Link to={`/documents/${signedPdfId}`}>
                    {t('projects.commercial.open_signed_pdf', 'Obrir PDF firmat')}
                  </Link>
                </Button>
              ) : null}
            </div>

            <div className="rounded-lg border border-border p-3 space-y-2">
              <p className="text-sm font-medium text-foreground">
                {t('projects.commercial.share_qr_title', 'QR del resum')}
              </p>
              <p className="text-xs text-muted-foreground">
                {t(
                  'projects.commercial.share_qr_help',
                  'Sense enllaç públic encara: el QR porta el resum del document per passar-lo al client.',
                )}
              </p>
              {qrDataUrl ? (
                <img
                  src={qrDataUrl}
                  alt=""
                  className="mx-auto h-44 w-44 rounded-md bg-white p-2"
                />
              ) : (
                <p className="text-xs text-muted-foreground">…</p>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
