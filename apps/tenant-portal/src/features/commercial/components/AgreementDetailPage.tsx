import { Link, Navigate, useParams } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ArrowLeft } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { PageShell } from '@/components/layout/PageShell'
import { useToast } from '@/hooks/use-toast'
import { useIsLargeScreen } from '@/hooks/useIsLargeScreen'
import { useTenant } from '@/contexts/TenantContext'
import {
  cancelCommercialAgreement,
  getCommercialAgreement,
  getOpenCommercialDecisionRequest,
  hasRecentAgreementSigningFailure,
  listAgreementVersionDecisionDeliveries,
  resumeCommercialAgreement,
  sendAgreementVersionForSignature,
  suspendCommercialAgreement,
} from '../api/commercialFlowService'
import { useCommercialDocumentSigningHub } from '../api/useCommercialSigningHub'
import { commercialSigningCentreHref } from '../utils/commercialSigningHub'
import { CommercialDeliveryTrace } from './CommercialDeliveryTrace'
import { SendCommercialDecisionDialog } from './SendCommercialDecisionDialog'
import {
  agreementKindLabel,
  formatAgreementIdentity,
  formatAgreementValidityLine,
} from '../utils/agreementIdentity'
import {
  enrichAgreementRows,
  type EnrichedAgreementRow,
} from '../utils/enrichAgreementRows'
import { AgreementFlowSteps } from './AgreementFlowSteps'
import { AgreementCoveragePlansSection } from './AgreementCoveragePlansSection'
import { AgreementBillingSection } from './AgreementBillingSection'
import { AgreementDocumentPanel } from './AgreementDocumentPanel'
import { CommercialTrailNav } from './CommercialTrailNav'
import { loadProjectAgreements } from './ProjectAgreementsSection'

export function AgreementDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const isLarge = useIsLargeScreen()
  const { activeTenant, activeRole } = useTenant()
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const tenantId = activeTenant?.id ?? ''
  const queryClient = useQueryClient()
  const [lifecycleBusy, setLifecycleBusy] = useState(false)
  const [sendDecisionOpen, setSendDecisionOpen] = useState(false)
  /** Prefer last send result over hub (hub is quote-keyed and can be stale/empty). */
  const [lastSentSubmissionId, setLastSentSubmissionId] = useState<string | null>(null)
  useEffect(() => {
    setLastSentSubmissionId(null)
  }, [id])

  const detailQuery = useQuery({
    queryKey: ['commercial_agreements', tenantId, 'detail', id],
    enabled: !!tenantId && !!id,
    queryFn: async () => {
      const row = await getCommercialAgreement(id!)
      if (!row) return null
      const [enriched] = await enrichAgreementRows([row])
      return enriched ?? null
    },
  })

  const selected = detailQuery.data

  const signingFailureQuery = useQuery({
    queryKey: ['commercial_agreements', tenantId, 'signing_failed', selected?.id],
    enabled: !!tenantId && !!selected?.id && selected.versionStatus === 'pending_signature',
    queryFn: () => hasRecentAgreementSigningFailure(selected!.id),
  })

  const openDecisionQuery = useQuery({
    queryKey: [
      'commercial',
      'decision_request',
      'open',
      'agreement',
      selected?.activeVersionId,
    ],
    enabled: !!selected?.activeVersionId,
    queryFn: () =>
      getOpenCommercialDecisionRequest({
        agreementVersionId: selected!.activeVersionId,
        documentId: selected!.sourceQuoteId,
      }),
    refetchOnWindowFocus: true,
  })

  const { data: signingHub } = useCommercialDocumentSigningHub(
    selected?.sourceQuoteId ?? undefined,
  )

  const deliveryTraceQuery = useQuery({
    queryKey: [
      'commercial',
      'decision_deliveries',
      'agreement',
      selected?.activeVersionId,
    ],
    enabled: !!selected?.activeVersionId,
    queryFn: () => listAgreementVersionDecisionDeliveries(selected!.activeVersionId!),
    refetchOnWindowFocus: true,
  })

  const siblingAgreementsQuery = useQuery({
    queryKey: [
      'project_agreements',
      selected?.primaryProjectId,
      selected?.clientId,
      'trail-siblings',
    ],
    enabled: !!selected?.primaryProjectId && !!selected?.clientId,
    queryFn: () =>
      loadProjectAgreements(selected!.primaryProjectId!, selected!.clientId),
  })
  const agreementTrailSiblings = useMemo(() => {
    if (!selected) return []
    const rows = siblingAgreementsQuery.data?.agreements ?? []
    return rows
      .filter((row) => row.id !== selected.id)
      .map((row) => ({
        label: t('field-service:detail.trail_agreement', 'Acord'),
        href: `/sales/agreements/${row.id}`,
      }))
  }, [siblingAgreementsQuery.data?.agreements, selected, t])

  async function invalidateAgreements() {
    await queryClient.invalidateQueries({ queryKey: ['commercial_agreements', tenantId] })
  }

  const sendMutation = useMutation({
    mutationFn: async (row: EnrichedAgreementRow) => {
      if (!row.activeVersionId || !tenantId) throw new Error('missing_version')
      return sendAgreementVersionForSignature({
        versionId: row.activeVersionId,
        tenantId,
        documentTitle: t('projects.commercial.agreement_pdf_title', 'Contracte de serveis'),
        signerName: row.clientName,
        issuerName: activeTenant?.name ?? null,
        sourceQuoteId: row.sourceQuoteId,
      })
    },
    onSuccess: async (result) => {
      if (result.submissionId) setLastSentSubmissionId(result.submissionId)
      await invalidateAgreements()
      await queryClient.invalidateQueries({
        queryKey: ['commercial', 'decision_request', 'open', 'agreement'],
      })
      await queryClient.invalidateQueries({
        queryKey: ['commercial', 'decision_deliveries', 'agreement'],
      })
      await queryClient.invalidateQueries({
        queryKey: ['commercial', 'signing_hub', 'by_document'],
      })
      toast({ title: t('projects.agreements.sent_ok', 'Acord enviat a firmar') })
    },
    onError: (err) => {
      toast({
        title: t('projects.agreements.sent_failed', 'No s’ha pogut enviar a firmar'),
        description: err instanceof Error ? err.message : String(err),
        variant: 'destructive',
      })
    },
  })

  const signingSubmissionId =
    lastSentSubmissionId ?? sendMutation.data?.submissionId ?? signingHub?.submissionId ?? null

  async function runLifecycle(
    action: 'cancel' | 'suspend' | 'resume',
    row: EnrichedAgreementRow,
  ) {
    if (!canManage) return
    setLifecycleBusy(true)
    try {
      if (action === 'cancel') {
        await cancelCommercialAgreement({ agreementId: row.id })
      } else if (action === 'suspend') {
        await suspendCommercialAgreement({ agreementId: row.id })
      } else {
        await resumeCommercialAgreement({ agreementId: row.id })
      }
      await invalidateAgreements()
      toast({
        title:
          action === 'cancel'
            ? t('projects.agreements.cancelled_ok', 'Acord cancel·lat')
            : action === 'suspend'
              ? t('projects.agreements.suspended_ok', 'Acord suspès')
              : t('projects.agreements.resumed_ok', 'Acord reactivat'),
      })
    } catch (err) {
      toast({
        title: t('projects.agreements.lifecycle_failed', 'No s’ha pogut actualitzar l’estat'),
        description: err instanceof Error ? err.message : String(err),
        variant: 'destructive',
      })
    } finally {
      setLifecycleBusy(false)
    }
  }

  if (!id) return <Navigate to="/sales/agreements" replace />

  if (detailQuery.isLoading) {
    return (
      <PageShell dense flush title={t('projects.agreements.detail_loading', 'Acord')}>
        <p className="text-sm text-muted-foreground">
          {t('projects.quotes.loading', 'Carregant…')}
        </p>
      </PageShell>
    )
  }

  if (detailQuery.error) {
    return (
      <PageShell dense flush title={t('projects.agreements.detail_loading', 'Acord')}>
        <p className="text-sm text-destructive">
          {t('projects.agreements.load_failed', 'No s’han pogut carregar els acords')}
        </p>
      </PageShell>
    )
  }

  if (!selected) {
    return <Navigate to="/sales/agreements" replace />
  }

  const operationalStarts = selected.cycleStartsOn ?? selected.startsOn ?? null
  const operationalEnds = selected.cycleEndsOn ?? selected.endsOn ?? null
  const identity = formatAgreementIdentity({
    primaryLineName: selected.primaryLineName,
    quoteNumber: selected.quoteNumber,
    kind: selected.kind,
    agreementStatus: selected.status,
    versionStatus: selected.versionStatus,
    startsOn: operationalStarts,
    t,
  })
  const validityLine = formatAgreementValidityLine({
    startsOn: operationalStarts,
    endsOn: operationalEnds,
    noticeDays: selected.noticeDays,
    t,
  })
  const kindLabel = agreementKindLabel(selected.kind, t)

  return (
    <>
    <PageShell
      dense
      flush
      title={t('projects.agreements.detail_title', 'Acord - {{identity}}', { identity })}
      subtitle={
        <CommercialTrailNav
          links={[
            {
              kind: 'order',
              label: t('field-service:detail.trail_order', 'Ordre'),
              href: selected.primaryProjectId
                ? `/field/orders/${selected.primaryProjectId}`
                : null,
              missingLabel: t('projects.quotes.no_order_linked', 'Sense ordre'),
            },
            {
              kind: 'quote',
              label: selected.quoteNumber
                ? t('field-service:detail.trail_quote_num', 'Pressupost {{number}}', {
                    number: selected.quoteNumber,
                  })
                : t('field-service:detail.trail_quote', 'Pressupost'),
              href: selected.sourceQuoteId ? `/sales/quotes/${selected.sourceQuoteId}` : null,
              missingLabel: t('field-service:detail.no_quote_badge', 'Sense pressupost'),
            },
            {
              kind: 'agreement',
              label: t('field-service:detail.trail_agreement', 'Acord'),
              href: `/sales/agreements/${selected.id}`,
              active: true,
              siblings:
                agreementTrailSiblings.length > 0 ? agreementTrailSiblings : undefined,
            },
          ]}
        />
      }
      actions={
        <>
          <Button asChild variant="ghost" size="sm" className="gap-1">
            <Link to="/sales/agreements">
              <ArrowLeft className="h-4 w-4" aria-hidden />
              {t('projects.agreements.back_to_list', 'Tornar als acords')}
            </Link>
          </Button>
          {canManage &&
          selected.versionStatus === 'draft' &&
          selected.activeVersionId ? (
            selected.sourceQuoteId ? (
              <Button
                type="button"
                size="sm"
                onClick={() => setSendDecisionOpen(true)}
              >
                {t('projects.commercial.prepare_agreement_send', 'Enviar a firmar (client)')}
              </Button>
            ) : (
              <Button
                type="button"
                size="sm"
                disabled={sendMutation.isPending}
                onClick={() => sendMutation.mutate(selected)}
              >
                {t('projects.commercial.prepare_agreement_send', 'Enviar a firmar (client)')}
              </Button>
            )
          ) : null}
          {selected.versionStatus === 'pending_signature' && signingSubmissionId ? (
            <Button asChild type="button" size="sm" variant="outline">
              <Link to={commercialSigningCentreHref(signingSubmissionId)}>
                {t(
                  'projects.commercial.view_signing_centre',
                  'Veure al Centre de signatures',
                )}
              </Link>
            </Button>
          ) : null}
          {canManage && selected.status === 'active' ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={lifecycleBusy}
              onClick={() => void runLifecycle('suspend', selected)}
            >
              {t('projects.agreements.suspend', 'Suspendre')}
            </Button>
          ) : null}
          {canManage && selected.status === 'suspended' ? (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={lifecycleBusy}
              onClick={() => void runLifecycle('resume', selected)}
            >
              {t('projects.agreements.resume', 'Reactivar')}
            </Button>
          ) : null}
          {canManage && selected.status !== 'cancelled' ? (
            <Button
              type="button"
              size="sm"
              variant="destructive"
              disabled={lifecycleBusy}
              onClick={() => void runLifecycle('cancel', selected)}
            >
              {t('projects.agreements.cancel', 'Cancel·lar')}
            </Button>
          ) : null}
        </>
      }
    >
      {(() => {
        const summaryBody = (
          <div className="space-y-5">
            <div className="min-w-0 space-y-1">
              <Link
                to={`/contacts/${selected.clientId}`}
                className="text-sm text-indigo-600 hover:underline"
              >
                {selected.clientName}
              </Link>
            </div>

            {signingFailureQuery.data ? (
              <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive">
                {t(
                  'projects.agreements.signing_failed_banner',
                  'La finalització de la firma ha fallat. Reintenta l’enviament o contacta suport.',
                )}
              </p>
            ) : null}

            <AgreementFlowSteps
              agreementStatus={selected.status}
              versionStatus={selected.versionStatus}
              fromQuote={!!selected.sourceQuoteId}
            />

            <CommercialDeliveryTrace
              variant="agreement"
              pending={
                selected.versionStatus === 'pending_signature' ||
                !!openDecisionQuery.data ||
                deliveryTraceQuery.data?.requestStatus === 'open'
              }
              submissionId={signingSubmissionId}
              rows={(() => {
                const fromVersion = deliveryTraceQuery.data?.deliveries ?? []
                if (fromVersion.length > 0) {
                  return fromVersion.map((d) => ({
                    id: d.id,
                    channel: d.channel,
                    at: d.created_at,
                    recipient: d.recipient_masked,
                    status: d.status,
                    error: d.error_code,
                  }))
                }
                const latest = openDecisionQuery.data?.latest_delivery
                if (!latest) return []
                return [
                  {
                    id: latest.id,
                    channel: latest.channel,
                    at: latest.created_at,
                    recipient: latest.recipient_masked,
                    status: latest.status,
                    error: latest.error_code,
                  },
                ]
              })()}
            />

            {kindLabel ? (
              <p className="text-sm text-muted-foreground">{kindLabel}</p>
            ) : null}
            {validityLine ? (
              <p className="text-sm text-muted-foreground">
                {validityLine}
                {selected.cycleNo != null
                  ? ` · ${t('projects.agreements.cycle_label', 'Cicle')} ${selected.cycleNo}`
                  : null}
                {selected.autoRenew
                  ? ` · ${t('projects.agreements.auto_renew_on', 'Auto-renovació')}`
                  : null}
              </p>
            ) : null}

            {(selected.slaResponseHours != null ||
              selected.slaResolutionHours != null ||
              selected.slaCoverageNotes) && (
              <p className="text-sm text-muted-foreground">
                {t('projects.agreements.sla_section', 'SLA (opcional)')}:{' '}
                {[
                  selected.slaResponseHours != null
                    ? `${t('projects.agreements.sla_response_label', 'Hores de resposta')} ${selected.slaResponseHours}h`
                    : null,
                  selected.slaResolutionHours != null
                    ? `${t('projects.agreements.sla_resolution_label', 'Hores de resolució')} ${selected.slaResolutionHours}h`
                    : null,
                  selected.slaCoverageNotes,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </p>
            )}

            {selected.templateName ? (
              <p className="text-sm text-muted-foreground">
                {t('projects.agreements.template_used', 'Plantilla')}: {selected.templateName}
              </p>
            ) : null}
            <p className="text-sm text-muted-foreground">
              {selected.projectNames.length > 0
                ? selected.projectNames.join(', ')
                : t('projects.agreements.no_projects', 'Sense projectes vinculats')}
            </p>

            {tenantId ? (
              <AgreementCoveragePlansSection
                agreementId={selected.id}
                clientId={selected.clientId}
                tenantId={tenantId}
                clientName={selected.clientName}
              />
            ) : null}

            <AgreementBillingSection
              agreementId={selected.id}
              canManage={canManage}
              billingCadence={selected.billingCadence}
              billingAmountCents={selected.billingAmountCents}
              billingCurrency={selected.billingCurrency}
              nextBillingOn={selected.nextBillingOn}
            />

            {selected.sourceQuoteId ? (
              <div className="flex flex-wrap gap-3 text-sm">
                <Link
                  className="text-indigo-600 hover:underline"
                  to={`/sales/quotes/${selected.sourceQuoteId}`}
                >
                  {t('projects.agreements.open_quote', 'Pressupost origen')}
                </Link>
              </div>
            ) : null}
          </div>
        )

        const documentPanel = (
          <AgreementDocumentPanel
            renderedDocumentId={selected.renderedDocumentId}
            signedDocumentId={selected.signedDocumentId}
            fullBodyTemplateId={selected.fullBodyTemplateId}
            templateName={selected.templateName}
          />
        )

        if (isLarge) {
          return (
            <div className="grid min-h-[calc(100dvh-10rem)] grid-cols-[minmax(0,18rem)_minmax(0,1fr)] gap-4 xl:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
              <div className="min-w-0 space-y-4 overflow-y-auto pr-1">{summaryBody}</div>
              <div className="min-h-0 sticky top-2 self-start h-[calc(100dvh-8rem)]">
                {documentPanel}
              </div>
            </div>
          )
        }

        return (
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
            <TabsContent value="document" className="mt-4 h-[min(80dvh,52rem)]">
              {documentPanel}
            </TabsContent>
          </Tabs>
        )
      })()}
    </PageShell>
    {selected.sourceQuoteId ? (
      <SendCommercialDecisionDialog
        documentId={selected.sourceQuoteId}
        open={sendDecisionOpen}
        onClose={() => setSendDecisionOpen(false)}
        onSent={() => {
          setSendDecisionOpen(false)
          void invalidateAgreements()
          void queryClient.invalidateQueries({
            queryKey: ['commercial', 'decision_request', 'open', 'agreement'],
          })
        }}
        existingRequest={openDecisionQuery.data}
      />
    ) : null}
    </>
  )
}
