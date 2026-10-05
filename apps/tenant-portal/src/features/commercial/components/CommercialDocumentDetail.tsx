import { useEffect, useState, type ReactNode } from 'react'
import { Link, useLocation } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, User } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { PageShell } from '@/components/layout/PageShell'
import { useToast } from '@/hooks/use-toast'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import {
  documentPathWithReturn,
  isAllowedReturnTo,
} from '@/lib/navigationReturn'
import {
  getCommercialDocumentDetail,
  listDeliveryNotesPage,
  listQuoteAgreementStates,
} from '../api/commercialFlowService'
import { CommercialNativeSignDialog } from './CommercialNativeSignDialog'
import { PrepareAgreementDialog } from './PrepareAgreementDialog'
import type { CommercialNativeSignAction } from '../utils/commercialNativeSign'
import type { CommercialDocumentDetail as DocDetail } from '../utils/commercialDocumentModel'
import {
  commercialFilename,
  COMMERCIAL_LIFECYCLE_EVENT_TYPES,
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
import { useTenant } from '@/contexts/TenantContext'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
import { CommercialRelationshipBadges } from './CommercialRelationshipBadges'
import { AgreementFlowSteps } from './AgreementFlowSteps'
import { commercialRelationshipBadges } from '../utils/commercialRelationshipBadges'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { useCommercialPdf } from '../hooks/useCommercialPdf'
import { useCommercialDocumentSigningHub } from '../api/useCommercialSigningHub'
import {
  commercialSignedPdfDocumentId,
  commercialSigningCentreHref,
} from '../utils/commercialSigningHub'
import { SIGNING_STATUS_CLASSES } from '@/features/signing/signingStatusColors'
import type { SigningStatus } from '@/features/signing/api/signingService'
import { cn } from '@/lib/utils'

export type CommercialDocumentDetailProps = {
  documentId: string
  /** List path for Enrere (page mode). */
  backTo: string
  onChanged?: () => void
  onShare?: () => void
  dmsReturnTo?: string | null
  /** Extra commercial actions (Cobrar, Rectificar, Obrir OS…). */
  commercialActions?: ReactNode
}

function PdfPanel({
  doc,
  pdf,
  preview,
  signedPdfId,
  dmsHref,
  showHtmlFallback,
  onToggleHtmlFallback,
  htmlFallbackOpen,
}: {
  doc: DocDetail
  pdf: ReturnType<typeof useCommercialPdf>
  preview: IssuedCommercialPreview | null
  signedPdfId: string | null
  dmsHref: (id: string) => string
  showHtmlFallback: boolean
  onToggleHtmlFallback: () => void
  htmlFallbackOpen: boolean
}) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()

  return (
    <div className="flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-border bg-card">
      <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-b border-border px-3 py-2">
        {pdf.status === 'ready' && pdf.downloadUrl ? (
          <Button
            type="button"
            size="sm"
            variant="ghost"
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
        {pdf.renderedDocumentId ? (
          <Button type="button" size="sm" variant="ghost" asChild>
            <Link to={dmsHref(pdf.renderedDocumentId)}>
              {t('projects.commercial.open_dms', 'Obrir al DMS')}
            </Link>
          </Button>
        ) : null}
        {signedPdfId && signedPdfId !== pdf.renderedDocumentId ? (
          <Button type="button" size="sm" variant="ghost" asChild>
            <Link to={dmsHref(signedPdfId)}>
              {t('projects.commercial.open_signed_pdf', 'Obrir PDF firmat')}
            </Link>
          </Button>
        ) : null}
        {showHtmlFallback ? (
          <Button type="button" size="sm" variant="ghost" onClick={onToggleHtmlFallback}>
            {htmlFallbackOpen
              ? t('projects.commercial.hide_html_draft', 'Amagar esborrany HTML')
              : t('projects.commercial.show_html_draft', 'Veure esborrany HTML')}
          </Button>
        ) : null}
        {preview?.kind !== 'docx' ? (
          <Button
            type="button"
            size="sm"
            variant="ghost"
            className="ml-auto"
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
      </div>

      <div className="min-h-0 flex-1 overflow-auto bg-muted/30">
        {htmlFallbackOpen && preview?.kind === 'html' ? (
          <div className="flex min-h-full justify-center p-4 sm:p-6">
            <div className="w-full max-w-[52rem] rounded-lg border border-border bg-white p-4 shadow-sm sm:p-6">
              <iframe
                title={t('projects.commercial.view_html_draft', 'Esborrany HTML')}
                srcDoc={preview.html}
                className="block h-[min(70dvh,48rem)] min-h-[28rem] w-full rounded-md border border-border/60 bg-white"
              />
            </div>
          </div>
        ) : pdf.status === 'ready' && pdf.downloadUrl ? (
          <object
            data={pdf.downloadUrl}
            type="application/pdf"
            className="h-full min-h-[28rem] w-full"
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
                <a href={pdf.downloadUrl} target="_blank" rel="noreferrer">
                  {t('projects.commercial.share_pdf', 'Descarregar PDF')}
                </a>
              </Button>
            </div>
          </object>
        ) : pdf.status === 'pending' || pdf.status === 'loading' ? (
          <div className="space-y-2 p-6 text-sm text-muted-foreground">
            <p>{t('projects.commercial.pdf_generating', 'Generant PDF…')}</p>
            {preview?.kind === 'html' ? (
              <Button type="button" size="sm" variant="outline" onClick={onToggleHtmlFallback}>
                {t('projects.commercial.show_html_draft', 'Veure esborrany HTML')}
              </Button>
            ) : null}
          </div>
        ) : (
          <div className="space-y-2 p-6 text-sm text-muted-foreground">
            <p>
              {t(
                'projects.commercial.pdf_unavailable',
                'El PDF encara no està disponible.',
              )}
            </p>
            {preview?.kind === 'html' ? (
              <Button type="button" size="sm" variant="outline" onClick={onToggleHtmlFallback}>
                {t('projects.commercial.show_html_draft', 'Veure esborrany HTML')}
              </Button>
            ) : preview?.kind === 'docx' ? (
              <p>
                {t(
                  'projects.commercial.view_docx_use_pdf',
                  'Aquesta plantilla és DOCX: el PDF és la còpia fidel.',
                )}
              </p>
            ) : null}
          </div>
        )}
      </div>
    </div>
  )
}

export function CommercialDocumentDetail({
  documentId,
  backTo,
  onChanged,
  onShare,
  dmsReturnTo,
  commercialActions,
}: CommercialDocumentDetailProps) {
  const { t } = useTranslation(['projects', 'signing', 'common'])
  const location = useLocation()
  const queryClient = useQueryClient()
  const { toast } = useToast()
  const isLarge = useIsLargeScreen()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const { activeRole } = useTenant()
  const canPrepareAgreement = activeRole === 'owner' || activeRole === 'manager'
  const locationReturn = `${location.pathname}${location.search}`
  const resolvedDmsReturn =
    dmsReturnTo ??
    (isAllowedReturnTo(locationReturn) ? locationReturn : `/sales/quotes/${documentId}`)
  const dmsHref = (docId: string) => documentPathWithReturn(docId, resolvedDmsReturn)

  const [doc, setDoc] = useState<DocDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [signAction, setSignAction] = useState<CommercialNativeSignAction | null>(null)
  const [prepareOpen, setPrepareOpen] = useState(false)
  const [preview, setPreview] = useState<IssuedCommercialPreview | null>(null)
  const [htmlFallbackOpen, setHtmlFallbackOpen] = useState(false)

  const pdf = useCommercialPdf({
    documentId,
    tenantId: doc?.tenant_id ?? null,
    enabled: !!doc,
    initialRenderedDocumentId: doc?.rendered_document_id,
    initialPdfJobId: doc?.pdf_job_id,
  })
  const { data: signingHub } = useCommercialDocumentSigningHub(documentId)
  const { data: templates = [] } = useDocumentTemplates(doc?.tenant_id ?? undefined)
  const { data: agreementStates = [] } = useQuery({
    queryKey: ['commercial_agreements', 'by-quotes', documentId],
    queryFn: () => listQuoteAgreementStates([documentId]),
    enabled: !!documentId && doc?.doc_type !== 'delivery_note',
  })
  const agreement = agreementStates[0] ?? null
  const { data: deliveryPage } = useQuery({
    queryKey: ['delivery_notes', 'document-view', doc?.project_id, documentId],
    queryFn: () =>
      listDeliveryNotesPage({
        projectId: doc?.project_id,
        statusGroup: 'all',
        includeRectified: true,
        limit: 100,
      }),
    enabled: doc?.doc_type === 'delivery_note' && !!doc.project_id,
  })
  const deliveryRow = deliveryPage?.items.find((item) => item.id === documentId) ?? null
  const replacedBy = deliveryRow?.superseded_by_number
  const replaces = deliveryPage?.items.find((item) => item.id === deliveryRow?.supersedes_id)
    ?.doc_number
  const deliveryInvoiced = Boolean(deliveryRow?.external_invoice_ref || doc?.external_invoice_ref)
  const deliveryCancelled =
    doc?.status === 'cancelled' || deliveryRow?.collection_status === 'rectified'
  const templateName =
    templates.find((template) => template.id === doc?.full_body_template_id)?.name ?? null
  const relationshipBadges = commercialRelationshipBadges({
    docType: doc?.doc_type,
    formalizationMode: doc?.formalization_mode,
    templateId: doc?.full_body_template_id,
    templateName,
    agreementStatus: agreement?.status,
    versionStatus: agreement?.versionStatus,
  })

  useEffect(() => {
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
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- load once per documentId
  }, [documentId])

  useEffect(() => {
    if (!doc) {
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
  }, [doc])

  const showPrices = doc?.show_prices !== false
  const currency = doc?.currency || 'EUR'
  const effectiveStatus =
    doc?.status === 'issued' &&
    doc.valid_until &&
    new Date(doc.valid_until).getTime() < Date.now()
      ? 'expired'
      : doc?.status

  const canDecideAmendment = doc?.doc_type !== 'quote_amendment' || canEditPricing
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
    !!doc && effectiveStatus === 'issued' && doc.doc_type === 'delivery_note'
  const showPrepareAgreement =
    !!doc &&
    canPrepareAgreement &&
    doc.formalization_mode === 'separate_agreement' &&
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    (effectiveStatus === 'accepted' || effectiveStatus === 'signed')

  const signedPdfId = commercialSignedPdfDocumentId(signingHub)
  const showHtmlFallback =
    Boolean(preview?.kind === 'html') &&
    (pdf.status === 'pending' || pdf.status === 'loading' || pdf.status === 'error' || pdf.status === 'offline')

  const title = doc?.doc_number ?? documentId.slice(0, 8)

  const commercialHeaderActions = (
    <>
      {doc && onShare && doc.status !== 'cancelled' ? (
        <Button type="button" size="sm" onClick={onShare}>
          {t('projects.commercial.send', 'Enviar')}
        </Button>
      ) : null}
      {showDeliverySignFooter ? (
        <Button type="button" size="sm" variant="outline" onClick={() => setSignAction('delivery')}>
          {t('projects.commercial.sign_delivery', 'Signar conformitat')}
        </Button>
      ) : null}
      {showDecideFooter ? (
        <>
          <Button type="button" size="sm" variant="outline" onClick={() => setSignAction('reject')}>
            {t('projects.commercial.reject', 'Refusar')}
          </Button>
          <Button type="button" size="sm" onClick={() => setSignAction('accept')}>
            {t('projects.commercial.accept', 'Acceptar')}
          </Button>
        </>
      ) : null}
      {showPrepareAgreement ? (
        <Button type="button" size="sm" variant="outline" onClick={() => setPrepareOpen(true)}>
          {agreement
            ? t('projects.commercial.prepare_agreement_footer_send', 'Enviar el contracte a firmar')
            : t('projects.commercial.prepare_agreement', 'Preparar acord')}
        </Button>
      ) : null}
      {commercialActions}
      {signingHub?.submissionId ? (
        <Button type="button" size="sm" variant="outline" asChild>
          <Link to={commercialSigningCentreHref(signingHub.submissionId)}>
            {t('projects.commercial.open_signing_centre', 'Centre de signatures')}
          </Link>
        </Button>
      ) : null}
    </>
  )

  const summaryBody =
    loading || !doc ? (
      <p className="text-sm text-muted-foreground">
        {t('projects.commercial.share_loading', 'Carregant…')}
      </p>
    ) : (
      <div className="space-y-5">
        {signingHub?.signingStatus ||
        showOfficePending ||
        (doc.doc_type !== 'delivery_note' &&
          (doc.formalization_mode === 'signed_quote' ||
            doc.formalization_mode === 'separate_agreement')) ? (
          <section
            className={cn(
              'rounded-xl border px-4 py-3',
              effectiveStatus === 'rejected' ||
                effectiveStatus === 'expired' ||
                effectiveStatus === 'cancelled'
                ? 'border-amber-300 bg-amber-50 dark:border-amber-800 dark:bg-amber-950/30'
                : 'border-border bg-muted/30',
            )}
          >
            {signingHub?.signingStatus ? (
              <div className="mb-2 flex flex-wrap items-center gap-1.5">
                <span className="text-sm font-medium">
                  {t('projects.commercial.document_status', 'Estat del document')}
                </span>
                <Link
                  to={commercialSigningCentreHref(signingHub.submissionId)}
                  className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium hover:opacity-80 ${
                    SIGNING_STATUS_CLASSES[signingHub.signingStatus as SigningStatus] ??
                    'bg-violet-50 text-violet-700'
                  }`}
                >
                  {t(
                    `signing:center.status.${signingHub.signingStatus}`,
                    signingHub.signingStatus === 'completed'
                      ? 'Firmat digitalment'
                      : signingHub.signingStatus,
                  )}
                </Link>
              </div>
            ) : null}
            {doc.doc_type !== 'delivery_note' && doc.formalization_mode === 'signed_quote' ? (
              <p className="mt-2 text-sm text-muted-foreground">
                {t(
                  'projects.commercial.formalization_view_signed',
                  'Formalització: el pressupost acceptat és el contracte.',
                )}
              </p>
            ) : null}
            {doc.doc_type !== 'delivery_note' &&
            doc.formalization_mode === 'separate_agreement' ? (
              <div className="mt-2 space-y-2 text-sm text-muted-foreground">
                <AgreementFlowSteps
                  agreementStatus={agreement?.status}
                  versionStatus={agreement?.versionStatus}
                />
                {agreement ? (
                  <Link
                    to={`/sales/agreements?view=${agreement.id}`}
                    className="text-primary hover:underline"
                  >
                    {t(
                      'projects.commercial.prepare_agreement_open_list',
                      'Veure a Acords comercials',
                    )}
                  </Link>
                ) : null}
              </div>
            ) : null}
            {showOfficePending ? (
              <p className="mt-2 text-sm text-muted-foreground">
                {t(
                  'projects.commercial.office_must_approve',
                  'L’oficina ha d’aprovar abans de cobrar.',
                )}
              </p>
            ) : null}
          </section>
        ) : null}

        {(() => {
          const lifecycle = (doc.events ?? []).filter((event) =>
            (COMMERCIAL_LIFECYCLE_EVENT_TYPES as readonly string[]).includes(event.event_type),
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
              case 'invoice_cancelled':
                return t('projects.commercial.event_invoice_cancelled', 'Factura anul·lada')
              case 'payment_recorded':
                return t('projects.commercial.event_payment_recorded', 'Cobrat')
              case 'superseded':
                return t('projects.commercial.event_superseded', 'Substituït')
              case 'signed':
                return t('projects.commercial.event_signed', 'Signat')
              default:
                return type
            }
          }
          return (
            <section className="space-y-1.5 rounded-xl border border-border px-4 py-3">
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
                  {eventLabel(event.event_type)} {formatCommercialEventDate(event.occurred_at)}
                  {event.event_type === 'sent' && event.channel ? ` · ${event.channel}` : ''}
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
            <p className="font-medium text-foreground">{partyDisplayName(doc.seller_snapshot)}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">
              {t('projects.commercial.view_buyer', 'Client')}
            </p>
            <p className="font-medium text-foreground">
              {doc.client_id ? (
                <Link
                  to={`/contacts/${doc.client_id}`}
                  className="inline-flex items-center gap-1.5 underline-offset-2 hover:underline"
                >
                  {partyDisplayName(doc.buyer_snapshot)}
                  <User className="h-4 w-4 shrink-0 text-muted-foreground" aria-hidden />
                </Link>
              ) : (
                partyDisplayName(doc.buyer_snapshot)
              )}
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
            <li key={line.id} className="flex items-start justify-between gap-3 px-3 py-3">
              <div className="min-w-0">
                <p className="text-sm font-medium text-foreground">{line.name}</p>
                <p className="text-xs tabular-nums text-muted-foreground">
                  {Number(line.quantity)} {line.unit}
                  {showPrices ? ` · ${formatMoney(line.unit_price, currency)}` : ''}
                </p>
              </div>
              {showPrices ? (
                <p className="shrink-0 text-sm font-medium tabular-nums text-foreground">
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
            <div className="flex justify-between border-t border-border pt-1 text-base font-semibold text-foreground">
              <span>{t('projects.commercial.view_total', 'Total')}</span>
              <span className="tabular-nums">{formatMoney(doc.total, currency)}</span>
            </div>
            {doc.doc_type === 'delivery_note' && deliveryCancelled ? (
              <p className="pt-2 text-sm text-amber-700 dark:text-amber-300">
                {replacedBy
                  ? t('projects.collections.superseded_by', 'Substituït per {{number}}', {
                      number: replacedBy,
                    })
                  : t('projects.collections.status_rectified', 'Rectificat')}
              </p>
            ) : null}
            {doc.doc_type === 'delivery_note' && !deliveryCancelled && deliveryInvoiced ? (
              <p className="pt-2 text-sm text-muted-foreground">
                {t('projects.collections.included_in_invoice', 'Inclòs a la factura {{ref}}', {
                  ref: deliveryRow?.external_invoice_ref || doc.external_invoice_ref,
                })}
              </p>
            ) : null}
            {doc.doc_type === 'delivery_note' &&
            !deliveryCancelled &&
            !deliveryInvoiced &&
            deliveryRow ? (
              <div className="space-y-1 border-t border-border pt-2">
                {replaces ? (
                  <p className="text-xs text-muted-foreground">
                    {t('projects.collections.replaces_delivery', 'Substitueix {{number}}', {
                      number: replaces,
                    })}
                  </p>
                ) : null}
                <div className="flex justify-between text-muted-foreground">
                  <span>{t('projects.commercial.summary_paid', 'Cobrat')}</span>
                  <span className="tabular-nums">
                    {formatMoney(
                      (deliveryRow.direct_paid_cents + deliveryRow.inherited_paid_cents) / 100,
                      currency,
                    )}
                  </span>
                </div>
                <div className="flex justify-between font-medium text-foreground">
                  <span>
                    {deliveryRow.remaining_cents > 0
                      ? t('projects.collections.remaining', 'Pendent')
                      : t('projects.collections.status_paid', 'Pagat')}
                  </span>
                  <span className="tabular-nums">
                    {formatMoney(Math.max(0, deliveryRow.remaining_cents) / 100, currency)}
                  </span>
                </div>
              </div>
            ) : null}
          </section>
        ) : null}

        {doc.terms_text ? (
          <p className="whitespace-pre-wrap text-xs text-muted-foreground">{doc.terms_text}</p>
        ) : null}
      </div>
    )

  const pdfBlock = doc ? (
    <PdfPanel
      doc={doc}
      pdf={pdf}
      preview={preview}
      signedPdfId={signedPdfId}
      dmsHref={dmsHref}
      showHtmlFallback={showHtmlFallback}
      htmlFallbackOpen={htmlFallbackOpen}
      onToggleHtmlFallback={() => setHtmlFallbackOpen((v) => !v)}
    />
  ) : (
    <div className="rounded-xl border border-border p-6 text-sm text-muted-foreground">
      {t('projects.commercial.share_loading', 'Carregant…')}
    </div>
  )

  return (
    <>
      <PageShell
        dense
        flush
        title={title}
        subtitle={
          doc ? (
            <span className="inline-flex flex-wrap items-center gap-1.5">
              <CommercialDocumentStatusBadges doc={doc} t={t} />
              <CommercialRelationshipBadges kinds={relationshipBadges} />
            </span>
          ) : undefined
        }
        actions={
          <>
            <Button asChild variant="ghost" size="sm" className="gap-1">
              <Link to={backTo}>
                <ArrowLeft className="h-4 w-4" aria-hidden />
                {t('common:back', 'Tornar')}
              </Link>
            </Button>
            {commercialHeaderActions}
          </>
        }
      >
        {isLarge ? (
          <div className="grid min-h-[calc(100dvh-12rem)] grid-cols-[minmax(0,22rem)_minmax(0,1fr)] gap-4 xl:grid-cols-[minmax(0,26rem)_minmax(0,1fr)]">
            <div className="min-w-0 space-y-4 overflow-y-auto pr-1">{summaryBody}</div>
            <div className="min-h-0 sticky top-4 self-start h-[calc(100dvh-10rem)]">
              {pdfBlock}
            </div>
          </div>
        ) : (
          <Tabs defaultValue="summary" className="w-full">
            <TabsList>
              <TabsTrigger value="summary">
                {t('projects.commercial.view_tab_summary', 'Resum')}
              </TabsTrigger>
              <TabsTrigger value="document">
                {t('projects.commercial.view_tab_document', 'Document')}
              </TabsTrigger>
            </TabsList>
            <TabsContent value="summary" className="mt-4 space-y-4">
              {summaryBody}
            </TabsContent>
            <TabsContent value="document" className="mt-4 min-h-[28rem]">
              {pdfBlock}
            </TabsContent>
          </Tabs>
        )}
      </PageShell>

      {doc && showPrepareAgreement ? (
        <PrepareAgreementDialog
          open={prepareOpen}
          mode={agreement ? 'followup' : 'prepare'}
          tenantId={doc.tenant_id}
          documentId={doc.id}
          buyerName={partyDisplayName(doc.buyer_snapshot)}
          onOpenChange={setPrepareOpen}
          onChanged={() => {
            void queryClient.invalidateQueries({
              queryKey: ['commercial_agreements', 'by-quotes', documentId],
            })
            onChanged?.()
          }}
        />
      ) : null}

      {signAction ? (
        <CommercialNativeSignDialog
          documentId={documentId}
          action={signAction}
          open
          onClose={() => setSignAction(null)}
          onCompleted={() => {
            onChanged?.()
            setSignAction(null)
          }}
        />
      ) : null}
    </>
  )
}
