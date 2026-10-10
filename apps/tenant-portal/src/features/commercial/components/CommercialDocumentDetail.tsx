import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, MoreHorizontal, User } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
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
  getCommercialDocumentSignedArtifactStatus,
  getOpenCommercialDecisionRequest,
  listDeliveryNotesPage,
  listQuoteAgreementStates,
  revokeCommercialDecisionRequest,
  ensureProjectFromOrphanQuote,
} from '../api/commercialFlowService'
import { CommercialSummaryLines } from './CommercialSummaryLines'
import { OrphanQuoteComposer } from './OrphanQuoteComposer'
import { CommercialNativeSignDialog } from './CommercialNativeSignDialog'
import { CommercialOfficeRejectDialog } from './CommercialOfficeRejectDialog'
import { CommercialOfficeAcceptDialog } from './CommercialOfficeAcceptDialog'
import { SendCommercialDecisionDialog } from './SendCommercialDecisionDialog'
import {
  commercialDecisionRequestsEnabled,
  commercialDecisionSendCta,
} from '../utils/commercialDecisionSend'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { PrepareAgreementDialog } from './PrepareAgreementDialog'
import {
  commercialSigningChannelBadge,
  commercialSigningChannelLabelKey,
  commercialSigningProviderBadge,
  commercialSigningProviderLabelKey,
} from '../utils/commercialSigningBadges'
import type { CommercialDocumentDetail as DocDetail } from '../utils/commercialDocumentModel'
import { isOfficeAcceptedEvent } from '../utils/commercialDocumentModel'
import { parseAllowOfficeAccept } from '../utils/deviationApprovalThreshold'
import {
  commercialFilename,
  COMMERCIAL_LIFECYCLE_EVENT_TYPES,
  formatAddress,
  formatCommercialEventDate,
  formatMoney,
  commercialDocumentHeading,
  docTypeLabel,
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
import { resolveTenantSiteId } from '@/hooks/useSiteScope'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
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
import { CommercialDocumentPreviewRibbon } from './CommercialDocumentPreviewRibbon'

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
  showHtmlFallback,
  onToggleHtmlFallback,
  htmlFallbackOpen,
  ribbon,
}: {
  doc: DocDetail
  pdf: ReturnType<typeof useCommercialPdf>
  preview: IssuedCommercialPreview | null
  showHtmlFallback: boolean
  onToggleHtmlFallback: () => void
  htmlFallbackOpen: boolean
  ribbon?: { label: string; tone: 'cancelled' | 'invoiced' } | null
}) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()

  return (
    <div className="relative flex h-full min-h-0 flex-col overflow-hidden rounded-xl border border-border bg-card">
      {ribbon ? (
        <CommercialDocumentPreviewRibbon label={ribbon.label} tone={ribbon.tone} />
      ) : null}
      <div
        className={cn(
          'flex shrink-0 flex-wrap items-center gap-1.5 border-b border-border px-3 py-2',
          ribbon ? 'pl-24' : null,
        )}
      >
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
          <div className="flex h-full min-h-[36rem] justify-center p-2 sm:p-4">
            <div className="flex h-full w-full max-w-5xl flex-col rounded-lg border border-border bg-white p-2 shadow-sm sm:p-4">
              <iframe
                title={t('projects.commercial.view_html_draft', 'Esborrany HTML')}
                srcDoc={preview.html}
                className="block h-full min-h-[calc(100dvh-14rem)] w-full flex-1 rounded-md border border-border/60 bg-white"
              />
            </div>
          </div>
        ) : pdf.status === 'ready' && pdf.downloadUrl ? (
          <object
            data={pdf.downloadUrl}
            type="application/pdf"
            className="h-full min-h-[min(80dvh,52rem)] w-full"
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
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { toast } = useToast()
  const isLarge = useIsLargeScreen()
  const canEditPricing = usePermission('commercial.pricing.edit')
  const { activeRole, activeTenant, sites: tenantSites, selectedSiteId } = useTenant()
  const { data: effectiveSettings } = useEffectiveSettings({ tenantId: activeTenant?.id })
  const decisionEnabled = commercialDecisionRequestsEnabled(effectiveSettings)
  const allowOfficeAccept = parseAllowOfficeAccept(effectiveSettings)
  const isOfficeRole = activeRole === 'owner' || activeRole === 'manager'
  const canPrepareAgreement = isOfficeRole
  const locationReturn = `${location.pathname}${location.search}`
  const resolvedDmsReturn =
    dmsReturnTo ??
    (isAllowedReturnTo(locationReturn) ? locationReturn : `/sales/quotes/${documentId}`)
  const dmsHref = (docId: string) => documentPathWithReturn(docId, resolvedDmsReturn)

  const [doc, setDoc] = useState<DocDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [reloadToken, setReloadToken] = useState(0)
  const [signAction, setSignAction] = useState<'accept' | 'delivery' | null>(null)
  const [officeRejectOpen, setOfficeRejectOpen] = useState(false)
  const [officeAcceptOpen, setOfficeAcceptOpen] = useState(false)
  const [sendDecisionOpen, setSendDecisionOpen] = useState(false)
  const [sendDecisionResend, setSendDecisionResend] = useState(false)
  const [decisionBusy, setDecisionBusy] = useState(false)
  const [prepareOpen, setPrepareOpen] = useState(false)
  const [preview, setPreview] = useState<IssuedCommercialPreview | null>(null)
  const [htmlFallbackOpen, setHtmlFallbackOpen] = useState(false)
  const [ensureSitePickOpen, setEnsureSitePickOpen] = useState(false)
  const [ensureSiteId, setEnsureSiteId] = useState<string>('')
  const [ensureBusy, setEnsureBusy] = useState(false)
  const pendingCardRef = useRef<HTMLElement | null>(null)

  const { data: signingHub } = useCommercialDocumentSigningHub(documentId)
  const signedPreviewVersionId =
    signingHub?.signingStatus === 'completed' && signingHub.resultDocumentVersionId
      ? signingHub.resultDocumentVersionId
      : null
  const pdf = useCommercialPdf({
    documentId,
    tenantId: doc?.tenant_id ?? null,
    enabled: !!doc,
    initialRenderedDocumentId: doc?.rendered_document_id,
    initialPdfJobId: doc?.pdf_job_id,
    preferredVersionId: signedPreviewVersionId,
  })
  const openDecisionQuery = useQuery({
    queryKey: ['commercial', 'decision_request', 'open', documentId],
    queryFn: () => getOpenCommercialDecisionRequest(documentId),
    enabled: decisionEnabled && !!documentId,
    refetchOnWindowFocus: true,
    refetchInterval: (q) => (q.state.data?.status === 'open' ? 20_000 : false),
  })
  const openDecision = openDecisionQuery.data
  const artifactStatusQuery = useQuery({
    queryKey: ['commercial', 'signed_artifact', documentId],
    queryFn: () => getCommercialDocumentSignedArtifactStatus(documentId),
    enabled: decisionEnabled && !!documentId,
    refetchOnWindowFocus: true,
    refetchInterval: (q) =>
      q.state.data?.artifact_status === 'failed' ||
      q.state.data?.artifact_status === 'pending'
        ? 30_000
        : false,
  })
  const artifactStatus = artifactStatusQuery.data
  const { data: templates = [] } = useDocumentTemplates(doc?.tenant_id ?? undefined)
  const { data: agreementStates = [] } = useQuery({
    queryKey: ['commercial_agreements', 'by-quotes', documentId],
    queryFn: () => listQuoteAgreementStates([documentId]),
    enabled: !!documentId && doc?.doc_type !== 'delivery_note',
  })
  const agreement = agreementStates[0] ?? null
  const quoteExpired =
    !!doc?.valid_until && new Date(doc.valid_until).getTime() < Date.now()
  const sendCta = commercialDecisionSendCta({
    docStatus: doc?.status,
    formalizationMode: doc?.formalization_mode,
    hasOpenRequest: !!openDecision,
    decisionRequestsEnabled: decisionEnabled,
    isExpired: quoteExpired,
    agreementVersionStatus: agreement?.versionStatus,
    agreementRendered: !!agreement?.renderedDocumentId,
  })
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
  const deliveryInvoiced = Boolean(deliveryRow?.invoice_id || doc?.invoice_id)
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
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reload on documentId / explicit refresh
  }, [documentId, reloadToken])

  function refreshAfterDecision() {
    setDecisionBusy(true)
    setReloadToken((n) => n + 1)
    void queryClient.invalidateQueries({
      queryKey: ['commercial', 'signing_hub', 'by_document', documentId],
    })
    void queryClient.invalidateQueries({ queryKey: ['commercial_document', documentId] })
    void queryClient.invalidateQueries({ queryKey: ['commercial_documents'] })
    onChanged?.()
    setDecisionBusy(false)
  }

  const providerBadge = commercialSigningProviderBadge(signingHub?.signingProvider)
  const channelBadge = commercialSigningChannelBadge(signingHub?.signingType)

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
  const showOfficeAccept =
    showDecideFooter && allowOfficeAccept && isOfficeRole && canEditPricing
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
    (effectiveStatus === 'issued' ||
      effectiveStatus === 'accepted' ||
      effectiveStatus === 'signed')

  const signedPdfId = commercialSignedPdfDocumentId(signingHub)
  const showHtmlFallback =
    Boolean(preview?.kind === 'html') &&
    (pdf.status === 'pending' || pdf.status === 'loading' || pdf.status === 'error' || pdf.status === 'offline')

  const title = doc
    ? commercialDocumentHeading(doc, docTypeLabel(doc.doc_type))
    : t('projects.commercial.share_loading', 'Carregant…')

  const showPrepareAgreementBtn =
    showPrepareAgreement &&
    !(
      decisionEnabled &&
      (sendCta === 'send_for_accept' || sendCta === 'view_pending')
    )

  const commercialHeaderActions = (
    <>
      {sendCta === 'send_for_accept' ? (
        <Button
          type="button"
          size="sm"
          onClick={() => {
            setSendDecisionResend(false)
            setSendDecisionOpen(true)
          }}
        >
          {t('projects.commercial.decision_send_title', 'Enviar per acceptar')}
        </Button>
      ) : null}
      {sendCta === 'view_pending' && openDecision ? (
        <Button
          type="button"
          size="sm"
          onClick={() => {
            pendingCardRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
          }}
        >
          {t('projects.commercial.decision_view_pending', 'Veure resposta pendent')}
        </Button>
      ) : null}
      {doc && onShare && doc.status !== 'cancelled' && doc.status !== 'draft' ? (
        <Button
          type="button"
          size="sm"
          variant={sendCta === 'send_for_accept' || sendCta === 'view_pending' ? 'outline' : 'default'}
          onClick={onShare}
        >
          {t('projects.commercial.share_title_deliver', 'Només entregar')}
        </Button>
      ) : null}
      {showDeliverySignFooter ? (
        <Button type="button" size="sm" variant="outline" onClick={() => setSignAction('delivery')}>
          {t('projects.commercial.sign_delivery', 'Signar conformitat')}
        </Button>
      ) : null}
      {showDecideFooter && !decisionEnabled ? (
        <>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={decisionBusy}
            onClick={() => setOfficeRejectOpen(true)}
          >
            {t('projects.commercial.reject', 'Refusar')}
          </Button>
          {showOfficeAccept ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={decisionBusy}
              onClick={() => setOfficeAcceptOpen(true)}
            >
              {t(
                'projects.commercial.office_accept_cta',
                'Registrar acceptació (oficina)',
              )}
            </Button>
          ) : null}
          <Button
            type="button"
            size="sm"
            disabled={decisionBusy}
            onClick={() => setSignAction('accept')}
          >
            {t('projects.commercial.accept', 'Acceptar')}
          </Button>
        </>
      ) : null}
      {showDecideFooter && decisionEnabled ? (
        <>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={decisionBusy}
            onClick={() => setOfficeRejectOpen(true)}
          >
            {t('projects.commercial.decision_register_reject', 'Registrar refús')}
          </Button>
          {showOfficeAccept ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={decisionBusy}
              onClick={() => setOfficeAcceptOpen(true)}
            >
              {t(
                'projects.commercial.office_accept_cta',
                'Registrar acceptació (oficina)',
              )}
            </Button>
          ) : null}
        </>
      ) : null}
      {showPrepareAgreementBtn ? (
        <Button type="button" size="sm" variant="outline" onClick={() => setPrepareOpen(true)}>
          {agreement
            ? t('projects.commercial.prepare_agreement_footer_send', 'Enviar el contracte a firmar')
            : t('projects.commercial.prepare_agreement', 'Preparar acord')}
        </Button>
      ) : null}
      {commercialActions}
      {doc ? (
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button type="button" size="sm" variant="outline" className="gap-1">
              <MoreHorizontal className="h-4 w-4" aria-hidden />
              {t('projects.commercial.more_actions', 'Més')}
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            {pdf.renderedDocumentId ? (
              <DropdownMenuItem asChild>
                <Link to={dmsHref(pdf.renderedDocumentId)}>
                  {t('projects.commercial.open_dms', 'Obrir al DMS')}
                </Link>
              </DropdownMenuItem>
            ) : null}
            {signedPdfId && signedPdfId !== pdf.renderedDocumentId ? (
              <DropdownMenuItem asChild>
                <Link to={dmsHref(signedPdfId)}>
                  {t('projects.commercial.open_signed_pdf', 'Obrir PDF firmat')}
                </Link>
              </DropdownMenuItem>
            ) : null}
            {signingHub?.submissionId ? (
              <DropdownMenuItem asChild>
                <Link to={commercialSigningCentreHref(signingHub.submissionId)}>
                  {t('projects.commercial.open_signing_centre', 'Centre de signatures')}
                </Link>
              </DropdownMenuItem>
            ) : null}
            {showHtmlFallback ? (
              <DropdownMenuItem
                onSelect={() => setHtmlFallbackOpen((v) => !v)}
              >
                {htmlFallbackOpen
                  ? t('projects.commercial.hide_html_draft', 'Amagar esborrany HTML')
                  : t('projects.commercial.show_html_draft', 'Veure esborrany HTML')}
              </DropdownMenuItem>
            ) : null}
            {(pdf.renderedDocumentId ||
              signedPdfId ||
              signingHub?.submissionId ||
              showHtmlFallback) &&
            preview?.kind !== 'docx' ? (
              <DropdownMenuSeparator />
            ) : null}
            {preview?.kind !== 'docx' ? (
              <DropdownMenuItem
                onSelect={() => {
                  if (!doc) return
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
              </DropdownMenuItem>
            ) : null}
            {showDecideFooter && decisionEnabled && effectiveStatus === 'issued' ? (
              <>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  disabled={decisionBusy}
                  onSelect={() => setSignAction('accept')}
                >
                  {t('projects.commercial.decision_presential', 'Firma presencial')}
                </DropdownMenuItem>
                {showOfficeAccept ? (
                  <DropdownMenuItem
                    disabled={decisionBusy}
                    onSelect={() => setOfficeAcceptOpen(true)}
                  >
                    {t(
                      'projects.commercial.office_accept_cta',
                      'Registrar acceptació (oficina)',
                    )}
                  </DropdownMenuItem>
                ) : null}
              </>
            ) : null}
          </DropdownMenuContent>
        </DropdownMenu>
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
        {artifactStatus?.artifact_status === 'failed' ||
        (artifactStatus?.artifact_status === 'pending' &&
          artifactStatus.request_status === 'accepted' &&
          !artifactStatus.has_result_pdf) ? (
          <section className="rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 dark:border-amber-800 dark:bg-amber-950/30">
            <p className="text-sm font-medium text-foreground">
              {artifactStatus.artifact_status === 'failed'
                ? t(
                    'projects.commercial.decision_artifact_failed',
                    'PDF firmat pendent de sincronitzar',
                  )
                : t(
                    'projects.commercial.decision_artifact_pending',
                    'S’està recuperant el PDF firmat…',
                  )}
            </p>
            <p className="mt-1 text-xs text-muted-foreground">
              {t(
                'projects.commercial.decision_artifact_help',
                'La resposta del client ja està registrada. El PDF s’adjuntarà automàticament quan estigui disponible.',
              )}
            </p>
          </section>
        ) : null}

        {openDecision && decisionEnabled ? (
          <section
            ref={pendingCardRef}
            className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-3 dark:border-sky-800 dark:bg-sky-950/30"
          >
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div className="min-w-0 space-y-1">
                <p className="text-sm font-medium text-foreground">
                  {t('projects.commercial.decision_pending_title', 'Resposta pendent')}
                </p>
                <p className="text-xs text-muted-foreground">
                  {t('projects.commercial.decision_pending_expires', 'Caduca {{date}}', {
                    date: formatCommercialEventDate(openDecision.expires_at),
                  })}
                </p>
                {openDecision.latest_delivery ? (
                  <p className="text-xs text-muted-foreground">
                    {t('projects.commercial.decision_pending_delivery', '{{channel}} · {{status}}', {
                      channel: openDecision.latest_delivery.channel,
                      status: openDecision.latest_delivery.status,
                    })}
                    {openDecision.latest_delivery.recipient_masked
                      ? ` · ${openDecision.latest_delivery.recipient_masked}`
                      : ''}
                    {openDecision.latest_delivery.error_code
                      ? ` · ${openDecision.latest_delivery.error_code}`
                      : ''}
                  </p>
                ) : null}
                {openDecision.agreement_version_id ? (
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'projects.commercial.decision_pending_agreement',
                      'El client ha de firmar l’acord, no el pressupost.',
                    )}
                  </p>
                ) : null}
              </div>
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={decisionBusy}
                  onClick={() => {
                    setSendDecisionResend(true)
                    setSendDecisionOpen(true)
                  }}
                >
                  {t('projects.commercial.decision_resend_title', 'Reenviar sol·licitud')}
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={decisionBusy}
                  onClick={() => {
                    void (async () => {
                      setDecisionBusy(true)
                      try {
                        await revokeCommercialDecisionRequest({ requestId: openDecision.id })
                        toast({
                          title: t('projects.commercial.decision_revoked', 'Sol·licitud revocada'),
                        })
                        void openDecisionQuery.refetch()
                        refreshAfterDecision()
                      } catch (err) {
                        toast({
                          variant: 'destructive',
                          title: t('projects.commercial.error', 'Error comercial'),
                          description: err instanceof Error ? err.message : undefined,
                        })
                      } finally {
                        setDecisionBusy(false)
                      }
                    })()
                  }}
                >
                  {t('projects.commercial.decision_revoke', 'Revocar enviament')}
                </Button>
              </div>
            </div>
          </section>
        ) : null}

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
                {providerBadge ? (
                  <span className="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium bg-violet-50 text-violet-800 dark:bg-violet-950/40 dark:text-violet-200">
                    {t(
                      commercialSigningProviderLabelKey(providerBadge),
                      providerBadge === 'native' ? 'Firma pròpia' : 'DocuSeal',
                    )}
                  </span>
                ) : null}
                {channelBadge ? (
                  <span className="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium bg-sky-50 text-sky-800 dark:bg-sky-950/40 dark:text-sky-200">
                    {t(
                      commercialSigningChannelLabelKey(channelBadge),
                      channelBadge === 'presential' ? 'Presencial' : 'Remota',
                    )}
                  </span>
                ) : null}
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
                      ? t('projects.commercial.badge_signed', 'Firmat')
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
                return isOfficeAcceptedEvent([event])
                  ? t(
                      'projects.commercial.event_accepted_office',
                      'Acceptat per oficina',
                    )
                  : t('projects.commercial.event_accepted', 'Acceptat')
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

        <CommercialSummaryLines
          lines={doc.lines}
          currency={currency}
          showPrices={showPrices}
          subtotal={Number(doc.subtotal)}
          total={Number(doc.total)}
        />

        {showPrices ? (
          <section className="space-y-1 text-sm">
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
                  ref:
                    deliveryRow?.invoice_doc_number ||
                    doc.invoice_doc_number ||
                    '—',
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

  const previewRibbon =
    deliveryCancelled || doc?.status === 'cancelled'
      ? {
          label: t('projects.commercial.status_cancelled', 'Anul·lat'),
          tone: 'cancelled' as const,
        }
      : doc?.doc_type === 'delivery_note' && deliveryInvoiced
        ? {
            label: t('projects.sales.billing_invoiced', 'Facturat'),
            tone: 'invoiced' as const,
          }
        : null

  const pdfBlock = doc ? (
    <PdfPanel
      doc={doc}
      pdf={pdf}
      preview={preview}
      showHtmlFallback={showHtmlFallback}
      htmlFallbackOpen={htmlFallbackOpen}
      onToggleHtmlFallback={() => setHtmlFallbackOpen((v) => !v)}
      ribbon={previewRibbon}
    />
  ) : (
    <div className="rounded-xl border border-border p-6 text-sm text-muted-foreground">
      {t('projects.commercial.share_loading', 'Carregant…')}
    </div>
  )

  const orphanCreatedFromQuote = (doc?.events ?? []).some(
    (e) => e.payload?.project_created_from_quote === true,
  )
  const orphanDetailChip =
    doc &&
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment')
      ? orphanCreatedFromQuote
        ? t('projects.orphan.chip_os_new', 'Acceptat · OS nova')
        : !doc.project_id && (doc.status === 'accepted' || doc.status === 'signed')
          ? t('projects.orphan.chip_os_pending', 'Acceptat · OS pendent')
          : !doc.project_id && (doc.status === 'draft' || doc.status === 'issued')
            ? t('projects.orphan.chip_orphan', 'Sense ordre')
            : null
      : null

  const orphanQuote =
    !!doc &&
    (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
    !doc.project_id
  const orphanDraft = orphanQuote && doc.status === 'draft'

  async function runEnsureOs(siteId: string | null) {
    setEnsureBusy(true)
    try {
      const projectId = await ensureProjectFromOrphanQuote(documentId, siteId)
      try {
        const key = 'orphan-os-ack'
        const raw = localStorage.getItem(key)
        const map = raw ? (JSON.parse(raw) as Record<string, boolean>) : {}
        map[documentId] = true
        localStorage.setItem(key, JSON.stringify(map))
      } catch {
        /* ignore */
      }
      toast({
        title: t('projects.orphan.os_created', 'Ordre creada'),
        description: t(
          'projects.orphan.os_created_help',
          'Planifica-la a Agenda → Sense planificar.',
        ),
      })
      setEnsureSitePickOpen(false)
      setReloadToken((n) => n + 1)
      onChanged?.()
      navigate(`/field/orders/${projectId}?tab=prepare`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description:
          err instanceof Error
            ? err.message
            : t('projects.orphan.os_failed', "No s'ha pogut crear l'ordre"),
      })
    } finally {
      setEnsureBusy(false)
    }
  }

  function handleEnsureOsClick() {
    const resolved = resolveTenantSiteId({
      selectedSiteId,
      sites: tenantSites,
    })
    if (resolved) {
      void runEnsureOs(resolved)
      return
    }
    if (tenantSites.length > 1) {
      setEnsureSiteId(tenantSites[0]?.id ?? '')
      setEnsureSitePickOpen(true)
      return
    }
    void runEnsureOs(null)
  }

  const orphanForm = orphanQuote ? (
    <div className="space-y-2">
      <OrphanQuoteComposer
        documentId={documentId}
        status={doc.status}
        projectId={doc.project_id}
        lines={doc.lines}
        title={doc.title}
        formalizationMode={doc.formalization_mode}
        hasAgreement={!!agreement}
        onChanged={() => {
          setReloadToken((n) => n + 1)
          onChanged?.()
        }}
      />
      {doc.status === 'accepted' ? (
        <Button
          type="button"
          size="sm"
          disabled={ensureBusy}
          onClick={() => handleEnsureOsClick()}
        >
          {t('projects.orphan.ensure_os', 'Crear / reintentar ordre')}
        </Button>
      ) : null}
    </div>
  ) : null

  const orphanComposer =
    isLarge && orphanDraft ? (
      <div className="mb-4 flex flex-wrap items-start gap-4">
        <div className="w-full min-w-0 max-w-3xl">{orphanForm}</div>
        <aside className="sticky top-2 w-full max-w-sm shrink-0 space-y-4 lg:w-80">{summaryBody}</aside>
      </div>
    ) : (
      orphanForm && <div className="mb-4">{orphanForm}</div>
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
              {doc.doc_number ? (
                <span className="inline-flex items-center rounded-full border border-border px-2 py-0.5 text-[11px] font-medium tabular-nums">
                  {t('projects.orphan.doc_number_label', 'Núm. {{number}}', {
                    number: doc.doc_number,
                  })}
                </span>
              ) : null}
              <CommercialDocumentStatusBadges doc={doc} t={t} />
              {isOfficeAcceptedEvent(doc.events) ? (
                <span className="inline-flex items-center rounded-full border border-sky-300 bg-sky-50 px-2 py-0.5 text-[11px] font-medium text-sky-900 dark:border-sky-800 dark:bg-sky-950/40 dark:text-sky-100">
                  {t(
                    'projects.commercial.office_accept_badge',
                    'Acceptat per oficina',
                  )}
                </span>
              ) : null}
              <CommercialRelationshipBadges kinds={relationshipBadges} />
              {orphanDetailChip ? (
                <span className="inline-flex items-center rounded-full border border-amber-300 bg-amber-50 px-2 py-0.5 text-[11px] font-medium text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
                  {orphanDetailChip}
                </span>
              ) : null}
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
        {orphanComposer}
        {isLarge && orphanDraft ? (
          <div className="min-h-[min(70dvh,48rem)]">{pdfBlock}</div>
        ) : isLarge ? (
          <div className="grid min-h-[calc(100dvh-10rem)] grid-cols-[minmax(0,18rem)_minmax(0,1fr)] gap-4 xl:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
            <div className="min-w-0 space-y-4 overflow-y-auto pr-1">{summaryBody}</div>
            <div className="min-h-0 sticky top-2 self-start h-[calc(100dvh-8rem)]">
              {pdfBlock}
            </div>
          </div>
        ) : (
          <Tabs defaultValue="document" className="w-full">
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
            <TabsContent value="document" className="mt-4 min-h-[min(80dvh,52rem)]">
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
            refreshAfterDecision()
            setSignAction(null)
          }}
        />
      ) : null}

      <CommercialOfficeRejectDialog
        documentId={documentId}
        open={officeRejectOpen}
        onClose={() => setOfficeRejectOpen(false)}
        onCompleted={refreshAfterDecision}
      />

      <CommercialOfficeAcceptDialog
        documentId={documentId}
        open={officeAcceptOpen}
        onClose={() => setOfficeAcceptOpen(false)}
        onCompleted={refreshAfterDecision}
        separateAgreement={doc?.formalization_mode === 'separate_agreement'}
        openDecisionRequestId={openDecision?.id ?? null}
      />

      <SendCommercialDecisionDialog
        documentId={documentId}
        open={sendDecisionOpen}
        existingRequest={sendDecisionResend ? openDecision ?? null : null}
        onClose={() => {
          setSendDecisionOpen(false)
          setSendDecisionResend(false)
        }}
        onSent={() => {
          setSendDecisionOpen(false)
          setSendDecisionResend(false)
          void openDecisionQuery.refetch()
          void queryClient.invalidateQueries({
            queryKey: ['commercial_agreements', 'by-quotes', documentId],
          })
          refreshAfterDecision()
        }}
      />

      <Dialog open={ensureSitePickOpen} onOpenChange={setEnsureSitePickOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('projects.orphan.tenant_site_pick_title', 'Tria el local de l’ordre')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'projects.orphan.tenant_site_pick_help',
                'Aquest pressupost no té local. Tria quin centre de l’empresa crearà l’ordre de servei.',
              )}
            </DialogDescription>
          </DialogHeader>
          <label className="block space-y-1.5">
            <span className="text-sm font-medium">
              {t('projects.orphan.tenant_site_label', 'Local')}
            </span>
            <select
              className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 text-sm"
              value={ensureSiteId}
              onChange={(e) => setEnsureSiteId(e.target.value)}
            >
              {tenantSites.map((site) => (
                <option key={site.id} value={site.id}>
                  {site.name}
                </option>
              ))}
            </select>
          </label>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={ensureBusy}
              onClick={() => setEnsureSitePickOpen(false)}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              disabled={ensureBusy || !ensureSiteId}
              onClick={() => void runEnsureOs(ensureSiteId || null)}
            >
              {t('projects.orphan.tenant_site_pick_confirm', 'Crear ordre')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
