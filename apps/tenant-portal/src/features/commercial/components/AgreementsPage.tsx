import { useMemo, useState } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import {
  AGREEMENTS_PAGE_SIZE,
  cancelCommercialAgreement,
  hasRecentAgreementSigningFailure,
  listCommercialAgreementsPage,
  listPrimaryLineNames,
  resumeCommercialAgreement,
  sendAgreementVersionForSignature,
  suspendCommercialAgreement,
  type AgreementListPageRow,
} from '../api/commercialFlowService'
import {
  agreementKindLabel,
  formatAgreementIdentity,
  formatAgreementValidityLine,
} from '../utils/agreementIdentity'
import { commercialRelationshipBadges } from '../utils/commercialRelationshipBadges'
import { AGREEMENT_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'
import { AgreementFlowSteps } from './AgreementFlowSteps'
import { AgreementCoveragePlansSection } from './AgreementCoveragePlansSection'
import { AgreementBillingSection } from './AgreementBillingSection'
import { CommercialRelationshipBadges } from './CommercialRelationshipBadges'
import { CreateFrameworkAgreementDialog } from './CreateFrameworkAgreementDialog'

type EnrichedAgreementRow = AgreementListPageRow & {
  clientName: string
  quoteNumber: string | null
  primaryLineName: string | null
  templateName: string | null
  projectNames: string[]
}

async function enrichAgreementRows(rows: AgreementListPageRow[]): Promise<EnrichedAgreementRow[]> {
  if (rows.length === 0) return []
  const clientIds = [...new Set(rows.map((row) => row.clientId))]
  const agreementIds = rows.map((row) => row.id)
  const quoteIds = [
    ...new Set(rows.map((row) => row.sourceQuoteId).filter((id): id is string => !!id)),
  ]
  const templateIds = [
    ...new Set(rows.map((row) => row.fullBodyTemplateId).filter((id): id is string => !!id)),
  ]

  const [contactsResult, linksResult, quotesResult, templatesResult, lineNames] = await Promise.all([
    supabase.from('contacts').select('id, display_name').in('id', clientIds),
    supabase
      .from('commercial_agreement_projects' as never)
      .select('agreement_id, project_id')
      .in('agreement_id', agreementIds),
    quoteIds.length
      ? supabase.from('commercial_documents').select('id, doc_number').in('id', quoteIds)
      : Promise.resolve({ data: [], error: null }),
    templateIds.length
      ? supabase.from('document_templates').select('id, name').in('id', templateIds)
      : Promise.resolve({ data: [], error: null }),
    listPrimaryLineNames(quoteIds),
  ])
  if (contactsResult.error) throw contactsResult.error
  if (linksResult.error) throw linksResult.error
  if (quotesResult.error) throw quotesResult.error
  if (templatesResult.error) throw templatesResult.error

  const clientName = new Map(
    ((contactsResult.data ?? []) as Array<{ id: string; display_name: string | null }>).map(
      (row) => [row.id, row.display_name?.trim() || row.id.slice(0, 8)],
    ),
  )
  const quoteNumber = new Map(
    ((quotesResult.data ?? []) as Array<{ id: string; doc_number: string | null }>).map((row) => [
      row.id,
      row.doc_number,
    ]),
  )
  const templateName = new Map(
    ((templatesResult.data ?? []) as Array<{ id: string; name: string | null }>).map((row) => [
      row.id,
      row.name,
    ]),
  )

  const projectIds = [
    ...new Set(
      ((linksResult.data ?? []) as Array<{ agreement_id: string; project_id: string }>).map(
        (row) => row.project_id,
      ),
    ),
  ]
  const projectName = new Map<string, string>()
  if (projectIds.length > 0) {
    const { data: projects, error: projectsError } = await supabase
      .from('projects')
      .select('id, name')
      .in('id', projectIds)
    if (projectsError) throw projectsError
    for (const p of (projects ?? []) as Array<{ id: string; name: string | null }>) {
      projectName.set(p.id, p.name?.trim() || p.id.slice(0, 8))
    }
  }
  const projectsByAgreement = new Map<string, string[]>()
  for (const link of (linksResult.data ?? []) as Array<{
    agreement_id: string
    project_id: string
  }>) {
    const list = projectsByAgreement.get(link.agreement_id) ?? []
    const name = projectName.get(link.project_id)
    if (name && !list.includes(name)) list.push(name)
    projectsByAgreement.set(link.agreement_id, list)
  }

  return rows.map((row) => ({
    ...row,
    clientName: clientName.get(row.clientId) || row.clientId.slice(0, 8),
    quoteNumber: row.sourceQuoteId ? quoteNumber.get(row.sourceQuoteId) ?? null : null,
    primaryLineName: row.sourceQuoteId ? lineNames.get(row.sourceQuoteId) ?? null : null,
    templateName: row.fullBodyTemplateId ? templateName.get(row.fullBodyTemplateId) ?? null : null,
    projectNames: projectsByAgreement.get(row.id) ?? [],
  }))
}

export function AgreementsPage() {
  const { t } = useTranslation('projects')
  const location = useLocation()
  const isSalesHub = location.pathname.startsWith('/sales')
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const tenantId = activeTenant?.id ?? ''
  const queryClient = useQueryClient()
  const [createOpen, setCreateOpen] = useState(false)
  const [lifecycleBusy, setLifecycleBusy] = useState(false)
  const agreementsLabel = useSectorLabel(
    'agreement_plural',
    t('projects.agreements.title', 'Acords comercials'),
  )
  const [searchParams, setSearchParams] = useSearchParams()
  const viewId = searchParams.get('view')
  const rawSignature = searchParams.get('signature')
  const signature: 'all' | 'none' | 'pending' | 'signed' =
    rawSignature === 'none' || rawSignature === 'pending' || rawSignature === 'signed'
      ? rawSignature
      : 'all'
  const rawValidity = searchParams.get('validity')
  const validity: 'all' | 'active' | 'expiring' | 'finished' =
    rawValidity === 'active' || rawValidity === 'expiring' || rawValidity === 'finished'
      ? rawValidity
      : 'all'
  const statusFilter = searchParams.get('status') === 'suspended' ? 'suspended' : null

  const signatureFilter =
    signature === 'none' ? 'draft' : signature === 'all' ? 'all' : signature

  const listQuery = useInfiniteQuery({
    queryKey: ['commercial_agreements', tenantId, 'list', signatureFilter, validity, statusFilter],
    enabled: !!tenantId,
    initialPageParam: null as { createdAt: string; id: string } | null,
    queryFn: async ({ pageParam }) => {
      const page = await listCommercialAgreementsPage({
        limit: AGREEMENTS_PAGE_SIZE,
        cursor: pageParam,
        signatureFilter,
        validityFilter: validity,
      })
      const enriched = await enrichAgreementRows(page.rows)
      return { rows: enriched, nextCursor: page.nextCursor }
    },
    getNextPageParam: (last) => last.nextCursor,
  })

  const rows = useMemo(() => {
    const all = listQuery.data?.pages.flatMap((page) => page.rows) ?? []
    if (statusFilter === 'suspended') return all.filter((row) => row.status === 'suspended')
    return all
  }, [listQuery.data, statusFilter])

  const selected = useMemo(
    () => (viewId ? rows.find((row) => row.id === viewId) ?? null : null),
    [rows, viewId],
  )

  const signingFailureQuery = useQuery({
    queryKey: ['commercial_agreements', tenantId, 'signing_failed', selected?.id],
    enabled: !!tenantId && !!selected?.id && selected.versionStatus === 'pending_signature',
    queryFn: () => hasRecentAgreementSigningFailure(selected!.id),
  })

  function setSignature(next: 'all' | 'none' | 'pending' | 'signed') {
    const params = new URLSearchParams(searchParams)
    if (next === 'all') params.delete('signature')
    else params.set('signature', next)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  function setValidity(next: 'all' | 'active' | 'expiring' | 'finished') {
    const params = new URLSearchParams(searchParams)
    if (next === 'all') params.delete('validity')
    else params.set('validity', next)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  function clearStatusFilter() {
    const params = new URLSearchParams(searchParams)
    params.delete('status')
    setSearchParams(params, { replace: true })
  }

  function openDetail(id: string) {
    const params = new URLSearchParams(searchParams)
    params.set('view', id)
    setSearchParams(params, { replace: true })
  }

  function closeDetail() {
    const params = new URLSearchParams(searchParams)
    params.delete('view')
    setSearchParams(params, { replace: true })
  }

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
      })
    },
    onSuccess: async () => {
      await invalidateAgreements()
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

  const operationalStarts = selected?.cycleStartsOn ?? selected?.startsOn ?? null
  const operationalEnds = selected?.cycleEndsOn ?? selected?.endsOn ?? null

  return (
    <div
      className={
        isSalesHub
          ? 'space-y-5'
          : 'mx-auto max-w-4xl space-y-5 px-4 py-6'
      }
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          {!isSalesHub ? (
            <>
              <h1 className="text-2xl font-bold text-foreground">{agreementsLabel}</h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {t(
                  'projects.agreements.subtitle',
                  'Contractes preparats a partir d’un pressupost acceptat, o acords marc sense pressupost.',
                )}
              </p>
            </>
          ) : null}
          <div className={`flex flex-wrap gap-x-3 gap-y-1 ${isSalesHub ? '' : 'mt-1'}`}>
            {!isSalesHub ? (
              <Link to="/sales/quotes" className="text-sm text-indigo-600 hover:underline">
                {t('projects.quotes.title', 'Pressupostos')}
              </Link>
            ) : null}
            <Link to={AGREEMENT_TEMPLATES_HREF} className="text-sm text-indigo-600 hover:underline">
              {t('projects.agreements.templates_link', 'Plantilles de contracte')}
            </Link>
            <Link
              to={commercialTemplatesHref('commercial_agreement', { create: true })}
              className="text-sm text-indigo-600 hover:underline"
            >
              {t('projects.agreements.templates_new', 'Nova plantilla')}
            </Link>
          </div>
        </div>
        {tenantId && canManage ? (
          <Button type="button" size="sm" onClick={() => setCreateOpen(true)}>
            {t('projects.agreements.framework_new', 'Nou acord marc')}
          </Button>
        ) : null}
      </div>

      <CreateFrameworkAgreementDialog
        open={createOpen}
        tenantId={tenantId}
        onOpenChange={setCreateOpen}
        onCreated={(id) => {
          void invalidateAgreements()
          openDetail(id)
        }}
      />

      <div className="flex flex-wrap gap-4">
        <label className="flex max-w-xs flex-col gap-1 text-xs text-muted-foreground">
          {t('projects.quotes.filter_signature', 'Firma de l’acord')}
          <select
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
            value={signature}
            onChange={(event) =>
              setSignature(event.target.value as 'all' | 'none' | 'pending' | 'signed')
            }
          >
            <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
            <option value="none">{t('projects.quotes.filter_signature_none', 'Sense enviar')}</option>
            <option value="pending">
              {t('projects.commercial.badge_agreement_pending', 'Acord pendent de firma')}
            </option>
            <option value="signed">
              {t('projects.commercial.agreement_status_signed', 'Contracte signat')}
            </option>
          </select>
        </label>
        <label className="flex max-w-xs flex-col gap-1 text-xs text-muted-foreground">
          {t('projects.agreements.filter_validity', 'Vigència')}
          <select
            className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
            value={validity}
            onChange={(event) => setValidity(event.target.value as typeof validity)}
          >
            <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
            <option value="active">{t('projects.agreements.filter_active', 'Actius')}</option>
            <option value="expiring">
              {t('projects.agreements.filter_expiring', 'A caducar')}
            </option>
            <option value="finished">
              {t('projects.agreements.filter_finished', 'Finalitzats / cancel·lats')}
            </option>
          </select>
        </label>
        {statusFilter === 'suspended' ? (
          <div className="flex items-end gap-2">
            <p className="rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-foreground">
              {t('projects.agreements.filter_suspended_active', 'Filtre: suspesos')}
            </p>
            <Button type="button" size="sm" variant="ghost" onClick={clearStatusFilter}>
              {t('projects.quotes.filter_all', 'Tots')}
            </Button>
          </div>
        ) : null}
      </div>

      {selected ? (
        <section className="space-y-3 rounded-2xl border border-border bg-card p-4">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0 space-y-1">
              <h2 className="text-base font-semibold text-foreground">
                {formatAgreementIdentity({
                  primaryLineName: selected.primaryLineName,
                  quoteNumber: selected.quoteNumber,
                  kind: selected.kind,
                  agreementStatus: selected.status,
                  versionStatus: selected.versionStatus,
                  startsOn: operationalStarts,
                  t,
                })}
              </h2>
              <Link
                to={`/contacts/${selected.clientId}`}
                className="text-sm text-indigo-600 hover:underline"
              >
                {selected.clientName}
              </Link>
            </div>
            <Button type="button" size="sm" variant="ghost" onClick={closeDetail}>
              {t('projects.agreements.close_detail', 'Tancar')}
            </Button>
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
          />
          {agreementKindLabel(selected.kind, t) ? (
            <p className="text-sm text-muted-foreground">{agreementKindLabel(selected.kind, t)}</p>
          ) : null}
          {formatAgreementValidityLine({
            startsOn: operationalStarts,
            endsOn: operationalEnds,
            noticeDays: selected.noticeDays,
            t,
          }) ? (
            <p className="text-sm text-muted-foreground">
              {formatAgreementValidityLine({
                startsOn: operationalStarts,
                endsOn: operationalEnds,
                noticeDays: selected.noticeDays,
                t,
              })}
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

          <div className="flex flex-wrap gap-2">
            {canManage && selected.versionStatus === 'draft' && selected.activeVersionId ? (
              <Button
                type="button"
                size="sm"
                disabled={sendMutation.isPending}
                onClick={() => sendMutation.mutate(selected)}
              >
                {t('projects.commercial.prepare_agreement_send', 'Enviar a firmar (client)')}
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
          </div>

          <div className="flex flex-wrap gap-3 text-sm">
            {selected.sourceQuoteId ? (
              <Link
                className="text-indigo-600 hover:underline"
                to={`/sales/quotes/${selected.sourceQuoteId}`}
              >
                {t('projects.agreements.open_quote', 'Pressupost origen')}
              </Link>
            ) : null}
            {selected.renderedDocumentId ? (
              <Link
                className="text-indigo-600 hover:underline"
                to={`/documents/${selected.renderedDocumentId}`}
              >
                {t('projects.commercial.prepare_agreement_open_pdf', 'Obrir el PDF')}
              </Link>
            ) : (
              <span className="text-muted-foreground">
                {t(
                  'projects.agreements.no_pdf_yet',
                  'Encara no hi ha PDF: es crea en enviar a firmar.',
                )}
              </span>
            )}
          </div>
        </section>
      ) : null}

      {listQuery.isLoading ? (
        <p className="text-sm text-muted-foreground">{t('projects.quotes.loading', 'Carregant…')}</p>
      ) : null}
      {listQuery.error ? (
        <p className="text-sm text-destructive">
          {t('projects.agreements.load_failed', 'No s’han pogut carregar els acords')}
        </p>
      ) : null}
      {!listQuery.isLoading && !listQuery.error && rows.length === 0 ? (
        <p className="rounded-2xl border border-dashed border-border p-6 text-center text-sm text-muted-foreground">
          {t('projects.agreements.empty', 'Cap acord no coincideix amb el filtre.')}
        </p>
      ) : null}
      {rows.length > 0 ? (
        <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card">
          {rows.map((row) => {
            const identity = formatAgreementIdentity({
              primaryLineName: row.primaryLineName,
              quoteNumber: row.quoteNumber,
              kind: row.kind,
              agreementStatus: row.status,
              versionStatus: row.versionStatus,
              startsOn: row.cycleStartsOn ?? row.startsOn,
              t,
            })
            return (
              <li key={row.id} className="space-y-1.5 px-4 py-3">
                <button
                  type="button"
                  className="block w-full truncate text-left text-sm font-medium text-foreground hover:underline"
                  onClick={() => openDetail(row.id)}
                >
                  {identity}
                </button>
                <Link
                  to={`/contacts/${row.clientId}`}
                  className="block truncate text-sm text-indigo-600 hover:underline"
                  aria-label={t('projects.commercial.open_contact', 'Obrir fitxa del client')}
                >
                  {row.clientName}
                </Link>
                <div className="flex flex-wrap gap-1.5">
                  <CommercialRelationshipBadges
                    kinds={commercialRelationshipBadges({
                      docType: 'quote',
                      formalizationMode: 'separate_agreement',
                      agreementStatus: row.status,
                      versionStatus: row.versionStatus,
                    })}
                  />
                </div>
                {formatAgreementValidityLine({
                  startsOn: row.cycleStartsOn ?? row.startsOn,
                  endsOn: row.cycleEndsOn ?? row.endsOn,
                  noticeDays: row.noticeDays,
                  t,
                }) ? (
                  <p className="text-xs text-muted-foreground">
                    {formatAgreementValidityLine({
                      startsOn: row.cycleStartsOn ?? row.startsOn,
                      endsOn: row.cycleEndsOn ?? row.endsOn,
                      noticeDays: row.noticeDays,
                      t,
                    })}
                  </p>
                ) : null}
                <p className="text-xs text-muted-foreground">
                  {row.projectNames.length > 0
                    ? row.projectNames.join(', ')
                    : t('projects.agreements.no_projects', 'Sense projectes vinculats')}
                </p>
                <div className="flex flex-wrap gap-3 text-xs">
                  {row.sourceQuoteId ? (
                    <Link
                      className="text-indigo-600 hover:underline"
                      to={`/sales/quotes/${row.sourceQuoteId}`}
                    >
                      {t('projects.agreements.open_quote', 'Pressupost origen')}
                    </Link>
                  ) : null}
                  {row.renderedDocumentId ? (
                    <Link
                      className="text-indigo-600 hover:underline"
                      to={`/documents/${row.renderedDocumentId}`}
                    >
                      {t('projects.commercial.prepare_agreement_open_pdf', 'Obrir el PDF')}
                    </Link>
                  ) : null}
                </div>
              </li>
            )
          })}
        </ul>
      ) : null}

      {listQuery.hasNextPage ? (
        <div className="flex justify-center">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={listQuery.isFetchingNextPage}
            onClick={() => void listQuery.fetchNextPage()}
          >
            {t('projects.agreements.load_more', 'Carregar més')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}
