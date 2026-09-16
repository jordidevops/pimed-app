import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  acceptCommercialDocument,
  getCommercialDocumentDetail,
  rejectCommercialDocument,
} from '../api/commercialFlowService'
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
import { usePermission } from '@/hooks/usePermission'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
import { useCommercialPdf } from '../hooks/useCommercialPdf'

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
  const [busy, setBusy] = useState(false)
  const pdf = useCommercialPdf({
    documentId,
    tenantId: doc?.tenant_id ?? null,
    enabled: open && !!doc,
    initialRenderedDocumentId: doc?.rendered_document_id,
    initialPdfJobId: doc?.pdf_job_id,
  })

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

  if (!open) return null

  async function decide(kind: 'accept' | 'reject') {
    if (!doc) return
    setBusy(true)
    try {
      if (kind === 'accept') {
        await acceptCommercialDocument({ documentId: doc.id })
        toast({ title: t('projects.commercial.accepted', 'Acceptat') })
      } else {
        await rejectCommercialDocument({ documentId: doc.id })
        toast({ title: t('projects.commercial.rejected', 'Refusat') })
      }
      onChanged?.()
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(false)
    }
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

  return (
    <div className="fixed inset-0 z-50 bg-background flex flex-col">
      <header className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <p className="text-xs uppercase tracking-wide text-muted-foreground">
            {t('projects.commercial.view_mode', 'Mode client')}
          </p>
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
          {doc ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => {
                try {
                  printCommercialDocument(doc)
                } catch (err) {
                  toast({
                    variant: 'destructive',
                    title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                    description: err instanceof Error ? err.message : undefined,
                  })
                }
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

      <div className="flex-1 overflow-y-auto px-4 py-5 space-y-5 max-w-3xl w-full mx-auto">
        {loading || !doc ? (
          <p className="text-sm text-muted-foreground">
            {t('projects.commercial.share_loading', 'Carregant…')}
          </p>
        ) : (
          <>
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
                <CommercialDocumentStatusBadges doc={doc} t={t} />
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
          </>
        )}
      </div>

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
            disabled={busy}
            className="h-12"
            onClick={() => void decide('reject')}
          >
            {t('projects.commercial.reject', 'Refusar')}
          </Button>
          <Button
            type="button"
            size="lg"
            disabled={busy}
            className="h-12"
            onClick={() => void decide('accept')}
          >
            {t('projects.commercial.accept', 'Acceptar')}
          </Button>
        </footer>
      ) : null}
    </div>
  )
}
