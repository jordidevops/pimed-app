import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import {
  getCommercialDocumentDetail,
} from '../api/commercialFlowService'
import { CommercialNativeSignDialog } from './CommercialNativeSignDialog'
import type { CommercialNativeSignAction } from '../utils/commercialNativeSign'
import type { CommercialDocumentDetail } from '../utils/commercialDocumentModel'
import {
  commercialFilename,
  COMMERCIAL_LIFECYCLE_EVENT_TYPES,
  docTypeLabel,
  formatAddress,
  formatCommercialEventDate,
  formatMoney,
  partyDisplayName,
  taxTotalFromBreakdown,
} from '../utils/commercialDocumentModel'
import {
  downloadCommercialDocumentPdfFromUrl,
  printCommercialDocument,
} from '../utils/commercialDocumentPrint'
import {
  buildIssuedCommercialPreview,
  type IssuedCommercialPreview,
} from '../utils/buildIssuedCommercialHtml'
import { usePermission } from '@/hooks/usePermission'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
import { useCommercialPdf } from '../hooks/useCommercialPdf'
import { useCommercialDocumentSigningHub } from '../api/useCommercialSigningHub'
import {
  commercialSignedPdfDocumentId,
  commercialSigningCentreHref,
} from '../utils/commercialSigningHub'
import { SIGNING_STATUS_CLASSES } from '@/features/signing/signingStatusColors'
import type { SigningStatus } from '@/features/signing/api/signingService'

interface CommercialDocumentViewProps {
  documentId: string
  open: boolean
  onClose: () => void
  onChanged?: () => void
  onShare?: () => void
}

export function CommercialDocumentView({
  documentId,
  open,
  onClose,
  onChanged,
  onShare,
}: CommercialDocumentViewProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const [doc, setDoc] = useState<CommercialDocumentDetail | null>(null)
  const [loading, setLoading] = useState(false)
  const [signAction, setSignAction] = useState<CommercialNativeSignAction | null>(null)
  const [preview, setPreview] = useState<IssuedCommercialPreview | null>(null)
  const pdf = useCommercialPdf({
    documentId,
    tenantId: doc?.tenant_id ?? null,
    enabled: open && !!doc,
    initialRenderedDocumentId: doc?.rendered_document_id,
    initialPdfJobId: doc?.pdf_job_id,
  })
  const { data: signingHub } = useCommercialDocumentSigningHub(open ? documentId : null)

  useEffect(() => {
    if (!open) return
    let cancelled = false
    setLoading(true)
    void (async () => {
      try {
        const detail = await getCommercialDocumentDetail(documentId)
        if (!cancelled) setDoc(detail)
      } catch (err) {
        if (!cancelled) {
          toast({
            variant: 'destructive',
            title: t('projects.commercial.view_load_failed', "No s'ha pogut obrir el document"),
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

  useEffect(() => {
    if (!open || !doc) {
      setPreview(null)
      return
    }
    let cancelled = false
    void buildIssuedCommercialPreview(doc).then((next) => {
      if (!cancelled) setPreview(next)
    })
    return () => {
      cancelled = true
    }
  }, [open, doc])

  if (!open) return null

  function decide(kind: 'accept' | 'reject') {
    if (!doc) return
    setSignAction(kind)
  }

  const showPrices = doc?.show_prices !== false
  const currency = doc?.currency || 'EUR'
  const effectiveStatus =
    doc?.status === 'issued' &&
    doc.valid_until &&
    new Date(doc.valid_until).getTime() < Date.now()
      ? 'expired'
      : doc?.status

  const canDecideAmendment =
    doc?.doc_type !== 'quote_amendment' || canEditPricing
  const showDecideFooter =
    !!doc &&
    effectiveStatus === 'issued' &&
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    canDecideAmendment
  const showOfficePending =
    !!doc &&
    effectiveStatus === 'issued' &&
    doc.doc_type === 'quote_amendment' &&
    !canEditPricing
  const showDeliverySignFooter =
    !!doc &&
    effectiveStatus === 'issued' &&
    doc.doc_type === 'delivery_note'

  const signedPdfId = commercialSignedPdfDocumentId(signingHub)

  return (
    <div className="fixed inset-0 z-50 bg-background flex flex-col">
      <header className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <h2 className="text-lg font-semibold truncate text-foreground">
            {doc
              ? `${docTypeLabel(doc.doc_type)} ${doc.doc_number ?? ''}`.trim()
              : t('projects.commercial.share_loading', 'Carregant…')}
          </h2>
        </div>
        <div className="flex flex-wrap gap-1.5">
          {doc && onShare ? (
            <Button type="button" size="sm" variant="outline" onClick={onShare}>
              {t('projects.commercial.send', 'Enviar')}
            </Button>
          ) : null}
          {doc && pdf.status === 'ready' && pdf.downloadUrl ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                downloadCommercialDocumentPdfFromUrl(
                  pdf.downloadUrl!,
                  commercialFilename(doc, 'pdf'),
                )
              }}
            >
              {t('projects.commercial.share_pdf', 'Descarregar PDF')}
            </Button>
          ) : null}
          {doc && pdf.status === 'pending' ? (
            <Button type="button" size="sm" variant="outline" disabled>
              {t('projects.commercial.pdf_generating', 'Generant PDF…')}
            </Button>
          ) : null}
          {pdf.renderedDocumentId ? (
            <Button type="button" size="sm" variant="outline" asChild>
              <Link to={`/documents/${pdf.renderedDocumentId}`}>
                {t('projects.commercial.open_dms', 'Obrir al DMS')}
              </Link>
            </Button>
          ) : null}
          {signedPdfId && signedPdfId !== pdf.renderedDocumentId ? (
            <Button type="button" size="sm" variant="outline" asChild>
              <Link to={`/documents/${signedPdfId}`}>
                {t('projects.commercial.open_signed_pdf', 'Obrir PDF firmat')}
              </Link>
            </Button>
          ) : null}
          {signingHub?.submissionId ? (
            <Button type="button" size="sm" variant="outline" asChild>
              <Link to={commercialSigningCentreHref(signingHub.submissionId)}>
                {t('projects.commercial.open_signing_centre', 'Centre de signatures')}
              </Link>
            </Button>
          ) : null}
          {doc && preview?.kind !== 'docx' ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                void printCommercialDocument(doc).catch((err: unknown) => {
                  toast({
                    variant: 'destructive',
                    title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                    description: err instanceof Error ? err.message : undefined,
                  })
                })
              }}
            >
              {t('projects.commercial.share_print', 'Imprimir HTML')}
            </Button>
          ) : null}
          <Button type="button" size="sm" variant="ghost" onClick={onClose}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
        </div>
      </header>

      {loading || !doc ? (
        <div className="flex-1 overflow-y-auto px-4 py-5 max-w-3xl w-full mx-auto">
          <p className="text-sm text-muted-foreground">
            {t('projects.commercial.share_loading', 'Carregant…')}
          </p>
        </div>
      ) : (
        <Tabs defaultValue="summary" className="flex-1 min-h-0 flex flex-col">
          <div className="border-b border-border px-4">
            <TabsList>
              <TabsTrigger value="summary">
                {t('projects.commercial.view_tab_summary', 'Resum')}
              </TabsTrigger>
              <TabsTrigger value="document">
                {t('projects.commercial.view_tab_document', 'Document')}
              </TabsTrigger>
            </TabsList>
          </div>
          <TabsContent
            value="summary"
            className="flex-1 overflow-y-auto mt-0 px-4 py-5 space-y-5 max-w-3xl w-full mx-auto"
          >
            <section
              className={`rounded-xl border px-4 py-3 ${
                effectiveStatus === 'rejected' ||
                effectiveStatus === 'expired' ||
                effectiveStatus === 'cancelled'
                  ? 'border-amber-300 bg-amber-50 dark:border-amber-800 dark:bg-amber-950/30'
                  : 'border-border bg-muted/30'
              }`}
            >
              <div className="flex items-center justify-between gap-3">
                <span className="text-sm font-medium">
                  {t('projects.commercial.document_status', 'Estat del document')}
                </span>
                <div className="flex flex-wrap items-center justify-end gap-1.5">
                  <CommercialDocumentStatusBadges doc={doc} t={t} />
                  {signingHub?.signingStatus ? (
                    <Link
                      to={commercialSigningCentreHref(signingHub.submissionId)}
                      className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium hover:opacity-80 ${
                        SIGNING_STATUS_CLASSES[(signingHub.signingStatus as SigningStatus)]
                        ?? 'bg-violet-50 text-violet-700'
                      }`}
                    >
                      {t(
                        `signing:center.status.${signingHub.signingStatus}`,
                        signingHub.signingStatus === 'completed'
                          ? 'Firmat digitalment'
                          : signingHub.signingStatus,
                      )}
                    </Link>
                  ) : null}
                </div>
              </div>
              {(effectiveStatus === 'rejected' ||
                effectiveStatus === 'expired' ||
                effectiveStatus === 'cancelled') && (
                <p className="mt-1 text-xs text-muted-foreground">
                  {t(
                    'projects.commercial.terminal_read_only',
                    'Aquest document és definitiu i només es pot consultar.',
                  )}
                </p>
              )}
            </section>

            {(() => {
              const lifecycle = (doc.events ?? []).filter((event) =>
                (COMMERCIAL_LIFECYCLE_EVENT_TYPES as readonly string[]).includes(
                  event.event_type,
                ),
              )
              if (lifecycle.length === 0 && !doc.issued_at) return null
              const eventLabel = (type: string) => {
                switch (type) {
                  case 'issued':
                    return t('projects.commercial.event_issued', 'Emès')
                  case 'sent':
                    return t('projects.commercial.event_sent', 'Enviat')
                  case 'accepted':
                    return t('projects.commercial.event_accepted', 'Acceptat')
                  case 'rejected':
                    return t('projects.commercial.event_rejected', 'Refusat')
                  case 'cancelled':
                    return t('projects.commercial.event_cancelled', 'Anul·lat')
                  case 'superseded':
                    return t('projects.commercial.event_superseded', 'Substituït')
                  case 'signed':
                    return t('projects.commercial.event_signed', 'Signat')
                  default:
                    return type
                }
              }
              return (
                <section className="rounded-xl border border-border px-4 py-3 space-y-1.5">
                  <p className="text-sm font-medium text-foreground">
                    {t('projects.commercial.view_dates', 'Dates')}
                  </p>
                  {lifecycle.length === 0 && doc.issued_at ? (
                    <p className="text-sm text-muted-foreground">
                      {t('projects.commercial.event_issued', 'Emès')}{' '}
                      {formatCommercialEventDate(doc.issued_at)}
                    </p>
                  ) : null}
                  {lifecycle.map((event) => (
                    <p key={event.id} className="text-sm text-muted-foreground">
                      {eventLabel(event.event_type)}{' '}
                      {formatCommercialEventDate(event.occurred_at)}
                      {event.event_type === 'sent' && event.channel
                        ? ` · ${event.channel}`
                        : ''}
                    </p>
                  ))}
                </section>
              )
            })()}

            <section className="grid gap-3 sm:grid-cols-2">
              <div>
                <p className="text-xs text-muted-foreground">
                  {t('projects.commercial.view_seller', 'Emissor')}
                </p>
                <p className="font-medium text-foreground">
                  {partyDisplayName(doc.seller_snapshot)}
                </p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">
                  {t('projects.commercial.view_buyer', 'Client')}
                </p>
                <p className="font-medium text-foreground">
                  {partyDisplayName(doc.buyer_snapshot)}
                </p>
                {formatAddress(doc.service_address_snapshot) ? (
                  <p className="text-sm text-muted-foreground">
                    {formatAddress(doc.service_address_snapshot)}
                  </p>
                ) : null}
              </div>
            </section>

            <ul className="divide-y divide-border rounded-xl border border-border">
              {doc.lines.map((line) => (
                <li key={line.id} className="px-3 py-3 flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-foreground">{line.name}</p>
                    <p className="text-xs text-muted-foreground tabular-nums">
                      {Number(line.quantity)} {line.unit}
                      {showPrices ? ` · ${formatMoney(line.unit_price, currency)}` : ''}
                    </p>
                  </div>
                  {showPrices ? (
                    <p className="text-sm font-medium tabular-nums text-foreground shrink-0">
                      {formatMoney(line.line_total, currency)}
                    </p>
                  ) : null}
                </li>
              ))}
            </ul>

            {showPrices ? (
              <section className="space-y-1 text-sm">
                <div className="flex justify-between text-muted-foreground">
                  <span>{t('projects.commercial.view_subtotal', 'Base')}</span>
                  <span className="tabular-nums">{formatMoney(doc.subtotal, currency)}</span>
                </div>
                <div className="flex justify-between text-muted-foreground">
                  <span>{t('projects.commercial.view_tax', 'IVA')}</span>
                  <span className="tabular-nums">
                    {formatMoney(taxTotalFromBreakdown(doc.tax_breakdown), currency)}
                  </span>
                </div>
                <div className="flex justify-between text-base font-semibold text-foreground pt-1 border-t border-border">
                  <span>{t('projects.commercial.view_total', 'Total')}</span>
                  <span className="tabular-nums">{formatMoney(doc.total, currency)}</span>
                </div>
              </section>
            ) : null}

            {doc.terms_text ? (
              <p className="text-xs text-muted-foreground whitespace-pre-wrap">{doc.terms_text}</p>
            ) : null}
          </TabsContent>
          <TabsContent value="document" className="flex-1 min-h-0 mt-0 flex flex-col">
            {preview?.kind === 'docx' ? (
              <div className="px-4 py-5 space-y-3 max-w-3xl w-full mx-auto">
                <p className="text-sm text-muted-foreground">
                  {t(
                    'projects.commercial.view_docx_use_pdf',
                    'Aquesta plantilla és DOCX: el PDF és la còpia fidel. L’HTML per defecte no s’hi mostra.',
                  )}
                </p>
                {signedPdfId ? (
                  <Button type="button" size="sm" variant="outline" asChild>
                    <Link to={`/documents/${signedPdfId}`}>
                      {t('projects.commercial.open_signed_pdf', 'Obrir PDF firmat')}
                    </Link>
                  </Button>
                ) : pdf.status === 'ready' && pdf.downloadUrl ? (
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      downloadCommercialDocumentPdfFromUrl(
                        pdf.downloadUrl!,
                        commercialFilename(doc, 'pdf'),
                      )
                    }}
                  >
                    {t('projects.commercial.share_pdf', 'Descarregar PDF')}
                  </Button>
                ) : null}
              </div>
            ) : preview?.kind === 'html' ? (
              <iframe
                title={t('projects.commercial.view_tab_document', 'Document')}
                srcDoc={preview.html}
                className="w-full flex-1 min-h-[32rem] border-0 bg-white"
              />
            ) : (
              <p className="px-4 py-5 text-sm text-muted-foreground">
                {t('projects.commercial.share_loading', 'Carregant…')}
              </p>
            )}
          </TabsContent>
        </Tabs>
      )}

      {showOfficePending ? (
        <footer className="border-t border-border p-4 max-w-3xl w-full mx-auto">
          <p className="text-sm text-muted-foreground text-center">
            {t(
              'projects.commercial.office_must_approve',
              'L’oficina ha d’aprovar abans de cobrar.',
            )}
          </p>
        </footer>
      ) : null}

      {showDecideFooter ? (
        <footer className="border-t border-border p-4 grid grid-cols-2 gap-2 max-w-3xl w-full mx-auto">
          <Button
            type="button"
            size="lg"
            variant="outline"
            className="h-12"
            onClick={() => decide('reject')}
          >
            {t('projects.commercial.reject', 'Refusar')}
          </Button>
          <Button
            type="button"
            size="lg"
            className="h-12"
            onClick={() => decide('accept')}
          >
            {t('projects.commercial.accept', 'Acceptar')}
          </Button>
        </footer>
      ) : null}

      {showDeliverySignFooter ? (
        <footer className="border-t border-border p-4 max-w-3xl w-full mx-auto">
          <Button
            type="button"
            size="lg"
            className="h-12 w-full"
            onClick={() => setSignAction('delivery')}
          >
            {t('projects.commercial.sign_delivery', 'Signar conformitat')}
          </Button>
        </footer>
      ) : null}

      {signAction ? (
        <CommercialNativeSignDialog
          documentId={documentId}
          action={signAction}
          open
          onClose={() => setSignAction(null)}
          onCompleted={() => {
            onChanged?.()
            if (signAction !== 'delivery') onClose()
          }}
        />
      ) : null}
    </div>
  )
}
