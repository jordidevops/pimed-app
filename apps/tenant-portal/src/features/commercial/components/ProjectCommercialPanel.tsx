import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  acceptCommercialDocument,
  cancelCommercialDocument,
  issueCommercialDocument,
  listPaymentsForDocuments,
  listProjectCommercialDocuments,
  reissueCommercialQuote,
  rejectCommercialDocument,
  setDeliveryExternalInvoiceRef,
  type CommercialDocument,
} from '../api/commercialFlowService'
import {
  accountedPaidCents,
  allocatedPaidCents,
  advancePaidCentsForProject,
  canCollectDocument,
  remainingCentsForDocument,
} from '../utils/paymentAllocation'
import { CollectPaymentDialog } from './CollectPaymentDialog'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import {
  CommercialDocumentStatusBadges,
  resolveCommercialDocumentBadges,
} from './CommercialDocumentStatusBadge'
import { CommercialDocumentView } from './CommercialDocumentView'
import { PaymentReceiptSheet } from './PaymentReceiptSheet'
import { QuoteWaiverDialog } from './QuoteWaiverDialog'
import { ReissueQuoteDialog } from './ReissueQuoteDialog'
import { usePermission } from '@/hooks/usePermission'
import { supabase } from '@/lib/supabase'
import {
  commercialDocumentDivergesFromLiveTotal,
  liveProjectLinesTotalCents,
} from '../utils/quotePriceDrift'

export type CommercialPanelSection = 'authorize' | 'deliver' | 'summary'

interface ProjectCommercialPanelProps {
  projectId: string
  hasLines: boolean
  /** authorize = quotes/waiver; deliver = delivery notes + payments; summary = dossier list */
  section?: CommercialPanelSection
  embedded?: boolean
  showHeader?: boolean
  /** Optional controlled dialogs driven by the primary action bar */
  forceViewDocId?: string | null
  forceCollectDocId?: string | null
  forceReceiptPaymentId?: string | null
  onForceViewHandled?: () => void
  onForceCollectHandled?: () => void
  onForceReceiptHandled?: () => void
}

function matchesSection(doc: CommercialDocument, section: CommercialPanelSection): boolean {
  if (section === 'summary') return true
  if (section === 'authorize') {
    return doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment'
  }
  return doc.doc_type === 'delivery_note'
}

function effectiveStatus(doc: CommercialDocument): string {
  if (
    doc.status === 'issued' &&
    doc.valid_until &&
    new Date(doc.valid_until).getTime() < Date.now()
  ) {
    return 'expired'
  }
  return doc.status
}

export function ProjectCommercialPanel({
  projectId,
  hasLines,
  section = 'authorize',
  embedded = false,
  showHeader = true,
  forceViewDocId = null,
  forceCollectDocId = null,
  forceReceiptPaymentId = null,
  onForceViewHandled,
  onForceCollectHandled,
  onForceReceiptHandled,
}: ProjectCommercialPanelProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const [busy, setBusy] = useState(false)
  const [waiverOpen, setWaiverOpen] = useState(false)
  const [viewDocId, setViewDocId] = useState<string | null>(null)
  const [shareDocId, setShareDocId] = useState<string | null>(null)
  const [collectDocId, setCollectDocId] = useState<string | null>(null)
  const [receiptPaymentId, setReceiptPaymentId] = useState<string | null>(null)
  const [invoiceRef, setInvoiceRef] = useState('')
  const [invoiceSaving, setInvoiceSaving] = useState(false)
  const [reissueOpen, setReissueOpen] = useState(false)

  const effectiveViewId = forceViewDocId ?? viewDocId
  const effectiveCollectId = forceCollectDocId ?? collectDocId
  const effectiveReceiptId = forceReceiptPaymentId ?? receiptPaymentId

  const { data: docs = [], refetch } = useQuery({
    queryKey: ['commercial_documents', projectId],
    queryFn: () => listProjectCommercialDocuments(projectId),
    enabled: !!projectId,
  })

  const sectionDocs = useMemo(
    () => docs.filter((d) => matchesSection(d, section)),
    [docs, section],
  )
  const visibleDocs =
    section === 'authorize' ? sectionDocs.slice(0, 1) : sectionDocs
  const historyDocs =
    section === 'authorize' ? sectionDocs.slice(1) : []

  const docIds = useMemo(() => docs.map((d) => d.id), [docs])

  const { data: payments = [], refetch: refetchPayments } = useQuery({
    queryKey: ['commercial_payments', projectId, docIds.join(',')],
    queryFn: () => listPaymentsForDocuments(docIds),
    enabled: !!projectId && docIds.length > 0,
  })

  const { data: liveLines = [] } = useQuery({
    queryKey: ['project_lines', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('project_lines')
        .select('*')
        .eq('project_id', projectId)
        .order('position', { ascending: true })
      if (error) throw error
      return data ?? []
    },
    enabled: !!projectId && section === 'authorize',
  })

  const paymentsByDoc = useMemo(() => {
    const map = new Map<string, typeof payments>()
    for (const payment of payments) {
      const list = map.get(payment.document_id) ?? []
      list.push(payment)
      map.set(payment.document_id, list)
    }
    return map
  }, [payments])

  async function run(action: () => Promise<unknown>, okTitle: string) {
    setBusy(true)
    try {
      await action()
      toast({ title: okTitle })
      await refetch()
      queryClient.invalidateQueries({ queryKey: ['projects'] })
      queryClient.invalidateQueries({ queryKey: ['commercial_documents'] })
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

  const latestQuote = docs.find((d) => d.doc_type === 'quote')
  const latestDelivery = docs.find((d) => d.doc_type === 'delivery_note')
  async function saveInvoiceRef() {
    if (!latestDelivery) return
    setInvoiceSaving(true)
    try {
      await setDeliveryExternalInvoiceRef({
        documentId: latestDelivery.id,
        ref: invoiceRef.trim() || null,
      })
      toast({
        title: t('projects.commercial.invoice_ref_saved', 'Referència de factura desada'),
      })
      await refetch()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setInvoiceSaving(false)
    }
  }
  const collectDoc = effectiveCollectId
    ? docs.find((d) => d.id === effectiveCollectId)
    : null

  const showAuthorizeActions = section === 'authorize'
  const showDeliverActions = section === 'deliver'
  const showSummaryTotals = section === 'summary' || section === 'deliver'

  const deliveryPaidCents = latestDelivery
    ? allocatedPaidCents(latestDelivery, docs, payments)
    : 0
  const deliveryTotalCents = latestDelivery
    ? Math.round(Number(latestDelivery.total) * 100)
    : 0
  const deliveryRemaining = Math.max(0, deliveryTotalCents - deliveryPaidCents)
  const latestQuoteStatus = latestQuote ? effectiveStatus(latestQuote) : null
  const liveCents = liveProjectLinesTotalCents(liveLines)
  const quoteDiverges =
    !!latestQuote &&
    commercialDocumentDivergesFromLiveTotal(Number(latestQuote.total), liveCents)
  const issuedQuoteDiverges =
    quoteDiverges && latestQuoteStatus === 'issued'
  const acceptedQuoteDiverges =
    quoteDiverges &&
    (latestQuoteStatus === 'accepted' || latestQuoteStatus === 'signed')
  const terminalQuote =
    latestQuote &&
    (latestQuoteStatus === 'rejected' ||
      latestQuoteStatus === 'expired' ||
      latestQuoteStatus === 'cancelled')
      ? latestQuote
      : null

  useEffect(() => {
    setInvoiceRef(latestDelivery?.external_invoice_ref ?? '')
  }, [latestDelivery?.id, latestDelivery?.external_invoice_ref])

  const docTypeLabel = (doc: CommercialDocument) =>
    doc.doc_type === 'quote'
      ? t('projects.commercial.type_quote', 'Pressupost')
      : doc.doc_type === 'quote_amendment'
        ? t('projects.commercial.type_amendment', 'Ampliació')
        : t('projects.commercial.type_delivery', 'Albarà')

  const statusLabel = (doc: CommercialDocument, paidCents = 0) => {
    const [primary] = resolveCommercialDocumentBadges(doc, paidCents)
    return t(primary.labelKey, primary.labelFallback)
  }

  const title =
    section === 'authorize'
      ? t('projects.commercial.authorize_title', 'Autorització')
      : section === 'deliver'
        ? t('projects.commercial.deliver_title', 'Albarà i cobrament')
        : t('projects.commercial.summary_title', 'Resum comercial')

  const help =
    section === 'authorize'
      ? t(
          'projects.commercial.authorize_help',
          'Emet un pressupost a partir del full de preus, o registra una renúncia signada.',
        )
      : section === 'deliver'
        ? t(
            'projects.commercial.deliver_help',
            'Emet l’albarà, cobra i envia el comprovant.',
          )
        : t(
            'projects.commercial.summary_help',
            'Documents i cobraments d’aquesta ordre.',
          )

  return (
    <div
      className={
        embedded
          ? 'space-y-3'
          : 'space-y-3 rounded-xl border border-border bg-card p-4'
      }
    >
      {showHeader && (
        <div>
          <h3 className="text-base font-semibold text-foreground">{title}</h3>
          <p className="text-sm text-muted-foreground">{help}</p>
        </div>
      )}

      {showAuthorizeActions && terminalQuote && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 dark:border-amber-800 dark:bg-amber-950/30">
          <div className="flex items-center gap-2">
            <CommercialDocumentStatusBadges doc={terminalQuote} t={t} />
            <p className="text-sm font-medium">
              {t(
                'projects.commercial.terminal_quote_title',
                'Aquest pressupost ja no es pot decidir',
              )}
            </p>
          </div>
          <p className="mt-1 text-xs text-muted-foreground">
            {t(
              'projects.commercial.terminal_quote_help',
              'Es conserva a l’historial. Per continuar, crea un pressupost nou.',
            )}
          </p>
          <Button
            type="button"
            size="sm"
            className="mt-2"
            disabled={busy || !hasLines}
            onClick={() => setReissueOpen(true)}
          >
            {t('projects.commercial.reissue_confirm', 'Crear nou pressupost')}
          </Button>
        </div>
      )}

      {showAuthorizeActions && issuedQuoteDiverges && latestQuote && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 dark:border-amber-800 dark:bg-amber-950/30 space-y-2">
          <p className="text-sm font-medium">
            {t(
              'projects.commercial.price_drift_issued_title',
              'El full de preus ja no coincideix amb el pressupost emès',
            )}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.commercial.price_drift_issued_help',
              'El client veu l’import del document. Per crear-ne un de nou, descarta o refusa l’actual.',
            )}
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() =>
                run(
                  () => cancelCommercialDocument({ documentId: latestQuote.id }),
                  t('projects.commercial.cancelled', 'Pressupost descartat'),
                )
              }
            >
              {t('projects.commercial.discard', 'Descartar')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() =>
                run(
                  () => rejectCommercialDocument({ documentId: latestQuote.id }),
                  t('projects.commercial.rejected', 'Refusat'),
                )
              }
            >
              {t('projects.commercial.reject', 'Refusar')}
            </Button>
          </div>
        </div>
      )}

      {showAuthorizeActions && acceptedQuoteDiverges && (
        <div className="rounded-lg border border-border bg-muted/40 px-3 py-2">
          <p className="text-sm font-medium">
            {t(
              'projects.commercial.price_drift_accepted_title',
              'El full intern no coincideix amb l’import autoritzat',
            )}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.commercial.price_drift_accepted_help',
              'El pressupost acceptat no es descarta. Si cal, fes una ampliació o revisa les desviacions.',
            )}
          </p>
        </div>
      )}

      {showSummaryTotals && latestDelivery && (
        <div className="rounded-lg border border-border bg-muted/30 px-3 py-2 text-sm space-y-1">
          <div className="flex justify-between gap-2">
            <span className="text-muted-foreground">
              {t('projects.commercial.summary_delivery', 'Albarà emès')}
            </span>
            <span className="tabular-nums font-medium">
              {(deliveryTotalCents / 100).toFixed(2)} €
            </span>
          </div>
          <div className="flex justify-between gap-2">
            <span className="text-muted-foreground">
              {t('projects.commercial.summary_paid', 'Cobrat')}
            </span>
            <span className="tabular-nums font-medium">
              {(deliveryPaidCents / 100).toFixed(2)} €
            </span>
          </div>
          <div className="flex justify-between gap-2 border-t border-border/60 pt-1">
            <span className="text-muted-foreground">
              {t('projects.commercial.summary_remaining', 'Pendent')}
            </span>
            <span
              className={`tabular-nums font-semibold ${
                deliveryRemaining > 0 ? 'text-amber-700 dark:text-amber-300' : 'text-emerald-700 dark:text-emerald-300'
              }`}
            >
              {(deliveryRemaining / 100).toFixed(2)} €
            </span>
          </div>
        </div>
      )}

      {showDeliverActions &&
        latestDelivery &&
        (latestDelivery.status === 'issued' ||
          latestDelivery.status === 'signed' ||
          latestDelivery.status === 'accepted') && (
        <div className="space-y-1.5 rounded-lg border border-border px-3 py-2">
          <label className="text-sm font-medium text-foreground" htmlFor="external-invoice-ref">
            {t('projects.commercial.external_invoice_ref', 'Factura externa')}
          </label>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.commercial.external_invoice_help',
              'Número de factura al teu programa de facturació. No genera factura fiscal.',
            )}
          </p>
          <div className="flex flex-wrap gap-2">
            <Input
              id="external-invoice-ref"
              value={invoiceRef}
              onChange={(e) => setInvoiceRef(e.target.value)}
              placeholder={t('projects.commercial.external_invoice_ph', 'p. ex. F-2026-014')}
            />
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={
                invoiceSaving ||
                busy ||
                invoiceRef.trim() === (latestDelivery.external_invoice_ref ?? '').trim()
              }
              onClick={() => void saveInvoiceRef()}
            >
              {t('projects.commercial.external_invoice_save', 'Desar')}
            </Button>
          </div>
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        {showAuthorizeActions && !latestQuote && (
          <>
            <Button
              type="button"
              size="sm"
              disabled={busy || !hasLines}
              onClick={() =>
                run(
                  () =>
                    issueCommercialDocument({
                      projectId,
                      docType: 'quote',
                    }),
                  t('projects.commercial.quote_issued', 'Pressupost emès'),
                )
              }
            >
              {t('projects.commercial.issue_quote', 'Emetre pressupost')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() => setWaiverOpen(true)}
            >
              {t('projects.commercial.waiver_cta', 'Renúncia al pressupost')}
            </Button>
          </>
        )}
        {showDeliverActions && (
          <Button
            type="button"
            size="sm"
            disabled={busy || !hasLines}
            onClick={() =>
              run(
                () =>
                  issueCommercialDocument({
                    projectId,
                    docType: 'delivery_note',
                    showPrices: true,
                  }),
                t('projects.commercial.delivery_issued', 'Albarà emès'),
              )
            }
          >
            {t('projects.commercial.issue_delivery', 'Emetre albarà')}
          </Button>
        )}
      </div>

      <QuoteWaiverDialog
        projectId={projectId}
        open={waiverOpen}
        onClose={() => setWaiverOpen(false)}
        onSaved={() => {
          void refetch()
          queryClient.invalidateQueries({ queryKey: ['projects'] })
          queryClient.invalidateQueries({ queryKey: ['quote_waivers', projectId] })
        }}
      />

      <ReissueQuoteDialog
        open={reissueOpen}
        busy={busy}
        onOpenChange={setReissueOpen}
        onConfirm={() => {
          if (!terminalQuote) return
          void (async () => {
            setBusy(true)
            try {
              await reissueCommercialQuote({ previousDocumentId: terminalQuote.id })
              toast({
                title: t('projects.commercial.reissue_created', 'Nou pressupost emès'),
              })
              setReissueOpen(false)
              await refetch()
              queryClient.invalidateQueries({ queryKey: ['projects'] })
              queryClient.invalidateQueries({ queryKey: ['commercial_documents'] })
            } catch (err) {
              toast({
                variant: 'destructive',
                title: t('projects.commercial.error', 'Error comercial'),
                description: err instanceof Error ? err.message : undefined,
              })
            } finally {
              setBusy(false)
            }
          })()
        }}
      />

      {effectiveViewId ? (
        <CommercialDocumentView
          documentId={effectiveViewId}
          open
          onClose={() => {
            setViewDocId(null)
            onForceViewHandled?.()
          }}
          onChanged={() => {
            void refetch()
            queryClient.invalidateQueries({ queryKey: ['projects'] })
          }}
          onShare={() => {
            setShareDocId(effectiveViewId)
          }}
        />
      ) : null}

      {shareDocId ? (
        <CommercialDocumentShareSheet
          documentId={shareDocId}
          open
          onClose={() => setShareDocId(null)}
        />
      ) : null}

      {collectDoc ? (
        <CollectPaymentDialog
          key={`${collectDoc.id}-${remainingCentsForDocument(collectDoc, docs, payments)}`}
          documentId={collectDoc.id}
          documentNumber={collectDoc.doc_number}
          remainingCents={remainingCentsForDocument(collectDoc, docs, payments)}
          previousPayments={paymentsByDoc.get(collectDoc.id) ?? []}
          advancePaidCents={
            collectDoc.doc_type === 'delivery_note'
              ? advancePaidCentsForProject(collectDoc.project_id, docs, payments)
              : 0
          }
          open
          onClose={() => {
            setCollectDocId(null)
            onForceCollectHandled?.()
          }}
          onCollected={(paymentId) => {
            void refetchPayments()
            setReceiptPaymentId(paymentId)
            onForceCollectHandled?.()
          }}
        />
      ) : null}

      {effectiveReceiptId ? (
        <PaymentReceiptSheet
          paymentId={effectiveReceiptId}
          open
          onClose={() => {
            setReceiptPaymentId(null)
            onForceReceiptHandled?.()
          }}
        />
      ) : null}

      {visibleDocs.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {section === 'authorize'
            ? t('projects.commercial.empty_authorize', 'Encara no hi ha pressupost ni renúncia')
            : section === 'deliver'
              ? t('projects.commercial.empty_deliver', 'Encara no hi ha albarà')
              : t('projects.commercial.empty', 'Encara no hi ha documents comercials')}
        </p>
      ) : (
        <ul className="space-y-2">
          {visibleDocs.map((doc) => {
            const docPayments = paymentsByDoc.get(doc.id) ?? []
            const paidCents = accountedPaidCents(doc, docs, payments)
            const remainingCents = remainingCentsForDocument(doc, docs, payments)
            const latestPayment = docPayments[0]
            const canCollect = canCollectDocument(doc, docs, payments)

            return (
              <li
                key={doc.id}
                className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2 rounded-lg border border-border px-3 py-2"
              >
                <div className="min-w-0">
                  <p className="text-sm font-medium text-foreground">
                    {docTypeLabel(doc)} {doc.doc_number ?? '—'}
                  </p>
                  <CommercialDocumentStatusBadges
                    doc={doc}
                    paidCents={paidCents}
                    t={t}
                    className="mt-1"
                  />
                  <p className="text-xs text-muted-foreground tabular-nums">
                    {Number(doc.total).toFixed(2)} €
                    {paidCents > 0
                      ? ` · ${t('projects.commercial.paid_of', 'Cobrat {{paid}} €', {
                          paid: (paidCents / 100).toFixed(2),
                        })}`
                      : ''}
                    {remainingCents > 0 && paidCents > 0
                      ? ` · ${t('projects.commercial.remaining', 'Pendent {{amount}} €', {
                          amount: (remainingCents / 100).toFixed(2),
                        })}`
                      : ''}
                  </p>
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {doc.status !== 'draft' && (
                    <>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => setViewDocId(doc.id)}
                      >
                        {t('projects.commercial.view', 'Veure')}
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => setShareDocId(doc.id)}
                      >
                        {t('projects.commercial.send', 'Enviar')}
                      </Button>
                    </>
                  )}
                  {effectiveStatus(doc) === 'issued' &&
                    (doc.doc_type === 'quote' ||
                      (doc.doc_type === 'quote_amendment' && canEditPricing)) && (
                    <>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() =>
                          run(
                            () => acceptCommercialDocument({ documentId: doc.id }),
                            t('projects.commercial.accepted', 'Acceptat'),
                          )
                        }
                      >
                        {t('projects.commercial.accept', 'Acceptar')}
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() =>
                          run(
                            () => rejectCommercialDocument({ documentId: doc.id }),
                            t('projects.commercial.rejected', 'Refusat'),
                          )
                        }
                      >
                        {t('projects.commercial.reject', 'Refusar')}
                      </Button>
                      {doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment' ? (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          disabled={busy}
                          onClick={() =>
                            run(
                              () => cancelCommercialDocument({ documentId: doc.id }),
                              t('projects.commercial.cancelled', 'Pressupost descartat'),
                            )
                          }
                        >
                          {t('projects.commercial.discard', 'Descartar')}
                        </Button>
                      ) : null}
                    </>
                  )}
                  {canCollect && (
                    <Button
                      type="button"
                      size="sm"
                      disabled={busy}
                      onClick={() => setCollectDocId(doc.id)}
                    >
                      {t('projects.commercial.collect', 'Cobrar')}
                    </Button>
                  )}
                  {latestPayment && (
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() => setReceiptPaymentId(latestPayment.id)}
                    >
                      {t('projects.commercial.send_receipt', 'Enviar comprovant')}
                    </Button>
                  )}
                </div>
              </li>
            )
          })}
        </ul>
      )}

      {historyDocs.length > 0 && (
        <details className="rounded-lg border border-border bg-muted/20">
          <summary className="cursor-pointer px-3 py-2 text-sm font-medium">
            {t('projects.commercial.history', 'Historial')} · {historyDocs.length}
          </summary>
          <ul className="space-y-2 border-t border-border p-3">
            {historyDocs.map((doc) => (
              <li
                key={doc.id}
                className="flex items-center justify-between gap-3 rounded-lg bg-background px-3 py-2"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium">
                    {docTypeLabel(doc)} {doc.doc_number ?? '—'}
                  </p>
                  <CommercialDocumentStatusBadges doc={doc} t={t} className="mt-1" />
                </div>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => setViewDocId(doc.id)}
                >
                  {t('projects.commercial.view', 'Veure')}
                </Button>
              </li>
            ))}
          </ul>
        </details>
      )}

      {section === 'authorize' && latestQuote && (
        <p className="text-xs text-muted-foreground">
          {t('projects.commercial.latest_quote', 'Darrer pressupost: {{num}} ({{status}})', {
            num: latestQuote.doc_number,
            status: statusLabel(latestQuote),
          })}
        </p>
      )}
      {section === 'deliver' && latestDelivery && (
        <p className="text-xs text-muted-foreground">
          {t('projects.commercial.latest_delivery', 'Darrer albarà: {{num}}', {
            num: latestDelivery.doc_number,
          })}
        </p>
      )}
    </div>
  )
}
