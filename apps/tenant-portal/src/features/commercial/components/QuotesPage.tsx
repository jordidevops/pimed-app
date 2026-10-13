import { useEffect, useMemo, useState } from 'react'
import { Link, Navigate, useLocation, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { PageShell } from '@/components/layout/PageShell'
import { InspectorSheet } from '@/components/layout/InspectorSheet'
import { ListViewToggle } from '@/components/layout/ListViewToggle'
import { FilterChips } from '@/components/layout/FilterChips'
import { useListViewMode } from '@/hooks/useListViewMode'
import { useListDensity } from '@/hooks/useListDensity'
import { SalesDocCard } from './SalesDocCard'
import { useToast } from '@/hooks/use-toast'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { SalesDataTable, type SalesDataTableColumn } from './SalesDataTable'
import {
  getCommercialDocumentDetail,
  listPaymentsForDocuments,
  listPrimaryLineNames,
  listQuoteAgreementStates,
  reissueCommercialQuote,
  searchCommercialDocuments,
  type CommercialDocument,
  type CommercialDocumentSearchHit,
  type QuoteAgreementState,
} from '../api/commercialFlowService'
import { formatCommercialEventDate } from '../utils/commercialDocumentModel'
import { CommercialSummaryLines } from './CommercialSummaryLines'
import { accountedPaidCents } from '../utils/paymentAllocation'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { useTenant } from '@/contexts/TenantContext'
import { isCommercialQuoteReissuable } from '../utils/pendingCommercialAction'
import { commercialRelationshipBadges } from '../utils/commercialRelationshipBadges'
import {
  QUOTE_TEMPLATES_HREF,
  commercialTemplatesHref,
} from '../utils/commercialTemplatePaths'
import { ClientFilterControl } from '@/features/contacts/components/ClientFilterControl'
import { SiteScopeFilter } from '@/components/layout/SiteScopeFilter'
import { useSiteScope } from '@/hooks/useSiteScope'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentView } from './CommercialDocumentView'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
import { CommercialRelationshipBadges } from './CommercialRelationshipBadges'
import {
  CreateQuoteWizardDialog,
  type QuoteWizardInitialType,
} from './CreateQuoteWizardDialog'
import { ReissueQuoteDialog } from './ReissueQuoteDialog'
import { getProjectsByClientId } from '@/features/projects/api/projectsService'

/** List chip: never claim «OS nova» without event evidence (detail-only). */
function orphanOfficeChip(
  doc: { id: string; status: string; project_id: string | null },
  t: (key: string, fallback: string) => string,
): string | null {
  if (doc.project_id) return null
  if (doc.status === 'accepted' || doc.status === 'signed') {
    return t('projects.orphan.chip_os_pending', 'Acceptat · OS pendent')
  }
  if (doc.status === 'draft' || doc.status === 'issued') {
    return t('projects.orphan.chip_orphan', 'Sense ordre')
  }
  return null
}

function quoteOriginLabel(
  doc: Pick<CommercialDocumentSearchHit, 'issued_as_orphan' | 'project_id'>,
  t: (key: string, fallback: string) => string,
): string {
  const orphan =
    doc.issued_as_orphan === true ||
    (doc.issued_as_orphan == null && !doc.project_id)
  return orphan
    ? t('projects.quotes.wizard_type_orphan_title', 'Només pressupost')
    : t('projects.quotes.wizard_type_prospect_title', 'Feina amb pressupost')
}

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

const DOC_TYPES: Array<CommercialDocument['doc_type'] | 'all'> = [
  'all',
  'quote',
  'quote_amendment',
]

const STATUSES = [
  'all',
  'issued',
  'accepted',
  'rejected',
  'expired',
  'cancelled',
  'signed',
  'draft',
] as const

function docTypeLabel(
  docType: CommercialDocument['doc_type'],
  t: (key: string, fallback: string) => string,
): string {
  if (docType === 'quote') return t('projects.commercial.type_quote', 'Pressupost')
  if (docType === 'quote_amendment') {
    return t('projects.commercial.type_amendment', 'Ampliació')
  }
  return t('projects.commercial.type_delivery', 'Albarà')
}

function quoteListTitle(
  doc: Pick<CommercialDocument, 'doc_type' | 'doc_number' | 'title'>,
  t: (key: string, fallback: string) => string,
): string {
  const custom = doc.title?.trim()
  if (custom) return custom
  const type = docTypeLabel(doc.doc_type, t)
  return doc.doc_number ? `${type} ${doc.doc_number}` : type
}

function quoteListNumberLabel(
  doc: Pick<CommercialDocument, 'doc_number' | 'title' | 'doc_type'>,
  t: (key: string, fallback: string, opts?: Record<string, string>) => string,
): string | null {
  if (doc.doc_number) {
    return t('projects.orphan.doc_number_label', 'Núm. {{number}}', {
      number: doc.doc_number,
    })
  }
  if (doc.title?.trim()) {
    return docTypeLabel(doc.doc_type, t)
  }
  return null
}

function orderLinkLabel(
  doc: Pick<CommercialDocumentSearchHit, 'project_id' | 'project_name' | 'status'>,
  t: (key: string, fallback: string) => string,
): string {
  if (doc.project_id) {
    return doc.project_name?.trim() || t('projects.quotes.with_order', 'Amb ordre')
  }
  return (
    orphanOfficeChip(doc, t) || t('projects.quotes.independent', 'Independent')
  )
}

function statusLabel(
  status: string,
  t: (key: string, fallback: string) => string,
): string {
  const fallbacks: Record<string, string> = {
    draft: 'Esborrany',
    issued: 'Pendent de resposta',
    accepted: 'Acceptat',
    signed: 'Signat',
    rejected: 'Refusat',
    expired: 'Caducat',
    cancelled: 'Anul·lat',
  }
  return t(`projects.commercial.status_${status}`, fallbacks[status] ?? status)
}

function canSendQuote(status: string): boolean {
  return status !== 'draft' && status !== 'cancelled'
}

function deliveryChannelLabel(
  channel: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  switch (channel) {
    case 'email':
      return t('projects.commercial.share_channel_email', 'Correu')
    case 'whatsapp':
    case 'whatsapp_portal_nudge':
      return t('projects.commercial.share_channel_whatsapp', 'WhatsApp')
    case 'copy_link':
      return t('projects.commercial.share_channel_link', 'Enllaç')
    case 'portal':
      return t('projects.commercial.share_channel_portal', 'Portal')
    case 'presential':
      return t('projects.commercial.share_channel_presential', 'Presencial')
    default:
      return channel || '—'
  }
}

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs)
    return () => window.clearTimeout(id)
  }, [value, delayMs])
  return debounced
}

export function QuotesPage({
  clientId,
  clientName,
  embedded = false,
}: {
  clientId?: string
  clientName?: string
  embedded?: boolean
} = {}) {
  const { t } = useTranslation(['projects', 'common', 'field-service'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const {
    sites: tenantSites,
    selectedSiteId,
    setSelectedSiteId,
    showSiteFilter,
    canUseAllSites,
  } = useSiteScope()
  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const isFieldService = useIsFieldService()
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const location = useLocation()
  const navigate = useNavigate()
  const isSalesHub = location.pathname.startsWith('/sales')
  const [searchParams, setSearchParams] = useSearchParams()
  const viewParam = !embedded && isSalesHub ? searchParams.get('view') : null
  const { mode: listMode, setMode: setListMode, effectiveMode } = useListViewMode(
    'sales.quotes',
    'cards',
  )
  const { density, setDensity } = useListDensity('sales.quotes', 'comfortable')

  const [search, setSearch] = useState('')
  const debouncedSearch = useDebouncedValue(search, 250)
  const [docType, setDocType] = useState<(typeof DOC_TYPES)[number]>('all')
  const statusFromUrl = searchParams.get('status')
  const [status, setStatus] = useState<(typeof STATUSES)[number]>(() =>
    STATUSES.includes(statusFromUrl as (typeof STATUSES)[number])
      ? (statusFromUrl as (typeof STATUSES)[number])
      : 'all',
  )
  const [issuedFrom, setIssuedFrom] = useState('')
  const [issuedTo, setIssuedTo] = useState('')
  const [expiredOnly, setExpiredOnly] = useState(false)
  const [totalMin, setTotalMin] = useState('')
  const [totalMax, setTotalMax] = useState('')
  const [formalization, setFormalization] = useState<'all' | 'signed_quote' | 'separate_agreement'>('all')
  const [hasAgreement, setHasAgreement] = useState<'all' | 'yes' | 'no'>('all')
  const [signature, setSignature] = useState<'all' | 'none' | 'pending' | 'signed'>('all')
  const [viewDocId, setViewDocId] = useState<string | null>(null)
  const [inspectId, setInspectId] = useState<string | null>(null)
  const [shareDocId, setShareDocId] = useState<string | null>(null)
  const [wizardOpen, setWizardOpen] = useState(false)
  const [wizardInitialType, setWizardInitialType] = useState<QuoteWizardInitialType | null>(
    null,
  )
  const [reissueDocId, setReissueDocId] = useState<string | null>(null)
  const [reissueBusy, setReissueBusy] = useState(false)

  const urlClientId = !embedded && !clientId
    ? (searchParams.get('client_id')?.trim() || null)
    : null
  const effectiveClientId = clientId ?? urlClientId

  function setUrlClientId(nextId: string | null) {
    if (embedded || clientId) return
    const next = new URLSearchParams(searchParams)
    if (nextId) next.set('client_id', nextId)
    else next.delete('client_id')
    setSearchParams(next, { replace: true })
  }

  useEffect(() => {
    if (embedded || isSalesHub) return
    const view = searchParams.get('view')
    if (view) setViewDocId(view)
  }, [searchParams, embedded, isSalesHub])

  useEffect(() => {
    if (embedded) return
    if (searchParams.get('orphan') === '1') {
      setWizardInitialType('orphan')
      setWizardOpen(true)
      const next = new URLSearchParams(searchParams)
      next.delete('orphan')
      setSearchParams(next, { replace: true })
    }
  }, [searchParams, embedded, setSearchParams])

  useEffect(() => {
    if (embedded || clientId) return
    const q = searchParams.get('q')
    if (q && !search) setSearch(q)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (embedded || clientId) return
    const next = searchParams.get('status')
    if (next && STATUSES.includes(next as (typeof STATUSES)[number])) {
      setStatus(next as (typeof STATUSES)[number])
      return
    }
    if (!next) setStatus('all')
  }, [searchParams, embedded, clientId])

  function setStatusFilter(next: (typeof STATUSES)[number]) {
    setStatus(next)
    if (embedded || clientId) return
    const params = new URLSearchParams(searchParams)
    if (next === 'all') params.delete('status')
    else params.set('status', next)
    setSearchParams(params, { replace: true })
  }

  function closeView() {
    setViewDocId(null)
    if (embedded || !searchParams.get('view')) return
    const next = new URLSearchParams(searchParams)
    next.delete('view')
    setSearchParams(next, { replace: true })
  }

  function openView(id: string) {
    // Same detail page as /sales/quotes «Obrir fitxa» (including contact tab).
    if (isSalesHub || embedded) {
      void navigate(`/sales/quotes/${id}`)
      return
    }
    setViewDocId(id)
    const next = new URLSearchParams(searchParams)
    next.set('view', id)
    setSearchParams(next, { replace: true })
  }

  function openInspect(id: string) {
    if (isSalesHub && !embedded) {
      setInspectId(id)
      return
    }
    openView(id)
  }

  const { data: inspectedDetail, isLoading: inspectedDetailLoading } = useQuery({
    queryKey: ['commercial_document', inspectId, 'inspector'],
    queryFn: () => getCommercialDocumentDetail(inspectId!),
    enabled: Boolean(isSalesHub && !embedded && inspectId),
  })

  useEffect(() => {
    if (!isSalesHub || !inspectId) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        setInspectId(null)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [isSalesHub, inspectId])

  const filters = useMemo(
    () => ({
      q: debouncedSearch,
      // "all" = only quote-like docs (never delivery notes / invoices).
      docTypes: docType === 'all' ? ['quote', 'quote_amendment'] : [docType],
      statuses: status === 'all' ? null : [status],
      issuedFrom: issuedFrom ? new Date(issuedFrom).toISOString() : null,
      issuedTo: issuedTo ? new Date(`${issuedTo}T23:59:59`).toISOString() : null,
      expiredOnly,
      totalMin: totalMin === '' ? null : Number(totalMin),
      totalMax: totalMax === '' ? null : Number(totalMax),
      limit: 100,
      clientId: effectiveClientId,
      siteId: selectedSiteId,
    }),
    [
      debouncedSearch,
      docType,
      status,
      issuedFrom,
      issuedTo,
      expiredOnly,
      totalMin,
      totalMax,
      effectiveClientId,
      selectedSiteId,
    ],
  )

  const {
    data: hits = [],
    isLoading,
    error,
  } = useQuery({
    queryKey: ['commercial_documents', 'search', filters],
    queryFn: () => searchCommercialDocuments(filters),
  })

  const prospectClientId = effectiveClientId
  const { data: prospectOrders = [] } = useQuery({
    queryKey: ['prospect_orders', prospectClientId, selectedSiteId],
    queryFn: async () => {
      const projects = await getProjectsByClientId(prospectClientId!)
      return projects.filter((project) => {
        if (project.commercial_stage !== 'prospect') return false
        if (project.status === 'cancelled' || project.status === 'completed') return false
        if (selectedSiteId && project.site_id !== selectedSiteId) return false
        return true
      })
    },
    enabled: !!prospectClientId,
  })

  const docIds = useMemo(() => hits.map((d) => d.id), [hits])

  const { data: payments = [] } = useQuery({
    queryKey: ['commercial_payments', 'quotes-search', docIds.join(',')],
    queryFn: () => listPaymentsForDocuments(docIds),
    enabled: docIds.length > 0,
  })

  const { data: agreementStates = [] } = useQuery({
    queryKey: ['commercial_agreements', 'by-quotes', docIds.join(',')],
    queryFn: () => listQuoteAgreementStates(docIds),
    enabled: docIds.length > 0,
  })

  const { data: lineNames = new Map<string, string>() } = useQuery({
    queryKey: ['commercial_document_lines', 'primary', docIds.join(',')],
    queryFn: () => listPrimaryLineNames(docIds),
    enabled: docIds.length > 0,
  })

  const agreementByQuote = useMemo(() => {
    const map = new Map<string, QuoteAgreementState>()
    for (const state of agreementStates) map.set(state.sourceQuoteId, state)
    return map
  }, [agreementStates])

  const templateNameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const template of templates) {
      if (template.id && template.name) map.set(template.id, template.name)
    }
    return map
  }, [templates])

  const visibleHits = useMemo(() => hits.filter((doc) => {
    if (doc.doc_type === 'delivery_note') return false
    if (formalization !== 'all') {
      if ((doc.formalization_mode ?? 'signed_quote') !== formalization) return false
    }
    const agreement = agreementByQuote.get(doc.id)
    if (hasAgreement === 'yes' && !agreement) return false
    if (hasAgreement === 'no' && agreement) return false
    if (signature === 'pending' && agreement?.versionStatus !== 'pending_signature') return false
    if (signature === 'signed' && agreement?.versionStatus !== 'signed') return false
    if (signature === 'none' && agreement && agreement.versionStatus !== 'draft' && agreement.versionStatus != null) {
      return false
    }
    return true
  }), [agreementByQuote, formalization, hasAgreement, hits, signature])

  function handleChanged() {
    void queryClient.invalidateQueries({ queryKey: ['commercial_documents', 'search'] })
    void queryClient.invalidateQueries({ queryKey: ['commercial_documents', 'client'] })
    void queryClient.invalidateQueries({ queryKey: ['commercial_payments', 'quotes-search'] })
  }

  const globalQuotesHref = clientId
    ? `/quotes?client_id=${encodeURIComponent(clientId)}`
    : '/quotes'

  async function confirmReissue() {
    if (!reissueDocId) return
    setReissueBusy(true)
    try {
      const docId = await reissueCommercialQuote({
        previousDocumentId: reissueDocId,
      })
      setReissueDocId(null)
      handleChanged()
      setViewDocId(docId)
      toast({
        title: t(
          'projects.commercial.reissue_created',
          'Nou pressupost creat',
        ),
      })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: message.includes('active_quote_already_exists')
          ? t(
              'projects.quotes.duplicate_active_exists',
              'Ja hi ha un pressupost actiu a aquesta ordre.',
            )
          : message.includes('quote_not_reissuable')
            ? t(
                'projects.quotes.duplicate_not_allowed',
                'Només es poden duplicar pressupostos refusats, caducats o anul·lats.',
              )
            : undefined,
      })
    } finally {
      setReissueBusy(false)
    }
  }

  const quoteFilterChips = [
    ...(debouncedSearch.trim()
      ? [{ key: 'q', label: debouncedSearch.trim(), onRemove: () => setSearch('') }]
      : []),
    ...(status !== 'all'
      ? [
          {
            key: 'status',
            label: statusLabel(status, t),
            onRemove: () => setStatusFilter('all'),
          },
        ]
      : []),
    ...(docType !== 'all'
      ? [
          {
            key: 'type',
            label: docTypeLabel(docType, t),
            onRemove: () => setDocType('all'),
          },
        ]
      : []),
    ...(expiredOnly
      ? [
          {
            key: 'expired',
            label: t('projects.quotes.filter_expired', 'Només caducats'),
            onRemove: () => setExpiredOnly(false),
          },
        ]
      : []),
  ]

  const statusQuickFilters = [
    { id: 'all' as const, label: t('projects.quotes.filter_all', 'Tots') },
    { id: 'issued' as const, label: statusLabel('issued', t) },
    { id: 'accepted' as const, label: statusLabel('accepted', t) },
    { id: 'rejected' as const, label: statusLabel('rejected', t) },
    { id: 'expired' as const, label: statusLabel('expired', t) },
    { id: 'cancelled' as const, label: statusLabel('cancelled', t) },
  ]

  const hideClientColumn = Boolean(embedded || clientId)
  const useSharedList = isSalesHub || embedded
  /** Contact tab keeps the table layout so it matches /sales/quotes. */
  const viewMode = embedded ? 'table' : effectiveMode

  const prospectSection =
    prospectOrders.length > 0 ? (
      <section className="space-y-2">
        <div>
          <h3 className="text-sm font-semibold text-foreground">
            {t('projects.prospect.list_title', 'Ordres en preparació')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.prospect.list_help',
              'Encara no hi ha pressupost emès. Obre l’ordre per omplir el full de preus i emetre’l.',
            )}
          </p>
        </div>
        <ul className="space-y-2">
          {prospectOrders.map((project) => (
            <li key={project.id}>
              <Link
                to={`${projectBase}/${project.id}?tab=prepare`}
                className="flex items-center justify-between gap-3 rounded-xl border border-amber-200/80 bg-amber-50/50 px-3 py-2.5 text-sm transition-colors hover:bg-amber-50 dark:border-amber-900 dark:bg-amber-950/20 dark:hover:bg-amber-950/40"
              >
                <span className="min-w-0">
                  <span className="block truncate font-medium text-foreground">
                    {project.name}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {t('projects.prospect.list_status', 'Prospecte · sense document emès')}
                  </span>
                </span>
                <Badge
                  variant="secondary"
                  className="shrink-0 bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100"
                >
                  {t('field-service:detail.prospect_badge', 'Prospecte')}
                </Badge>
              </Link>
            </li>
          ))}
        </ul>
      </section>
    ) : null

  const quoteToolbar = (
      <div className={useSharedList ? 'space-y-3' : 'space-y-3 rounded-2xl border border-border bg-card p-4'}>
        {prospectSection}
        <div className="flex flex-wrap items-center gap-2">
          <label className="relative block min-w-[12rem] flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              className="pl-9"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t(
                'projects.quotes.search_placeholder',
                'Títol, número, client, OS o text de línia…',
              )}
              aria-label={t('projects.quotes.search_aria', 'Cerca documents comercials')}
            />
          </label>
          {useSharedList && !embedded ? (
            <ListViewToggle
              mode={listMode}
              onModeChange={setListMode}
              density={density}
              onDensityChange={setDensity}
              showDensity={viewMode === 'table'}
            />
          ) : null}
          <Button
            type="button"
            className="shrink-0"
            disabled={wizardOpen}
            onClick={() => {
              setWizardInitialType(null)
              setWizardOpen(true)
            }}
          >
            <Plus className="mr-1.5 h-4 w-4" aria-hidden />
            {t('projects.quotes.create', 'Nou pressupost')}
          </Button>
        </div>
        {isSalesHub && !embedded ? (
          <p className="text-xs text-muted-foreground">
            {t(
              'projects.quotes.wizard_existing_order_note',
              'Si ja tens una ordre oberta, obre-la i emet el pressupost des de Preparar.',
            )}
            {' · '}
            <Link to="/sales/agreements" className="text-indigo-600 hover:underline">
              {t('projects.agreements.open', 'Acords comercials')}
            </Link>
            {' · '}
            <Link to={QUOTE_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
              {t('projects.quotes.manage_templates', 'Gestionar plantilles')}
            </Link>
            {' · '}
            <Link
              to={commercialTemplatesHref('quote', { create: true })}
              className="text-indigo-600 hover:underline"
            >
              {t('projects.quotes.templates_new', 'Nova plantilla')}
            </Link>
          </p>
        ) : null}
        {useSharedList ? (
              <div className="flex flex-wrap gap-1.5">
                {statusQuickFilters.map((filter) => (
                  <Button
                    key={filter.id}
                    type="button"
                    size="sm"
                    variant={status === filter.id ? 'default' : 'outline'}
                    className="h-7 rounded-full px-2.5 text-xs"
                    onClick={() => setStatusFilter(filter.id)}
                  >
                    {filter.label}
                  </Button>
                ))}
              </div>
            ) : null}
        {showSiteFilter ? (
          <SiteScopeFilter
            sites={tenantSites}
            value={selectedSiteId}
            onChange={setSelectedSiteId}
            canSelectAll={canUseAllSites}
          />
        ) : null}
        {useSharedList ? (
          <FilterChips
            chips={quoteFilterChips}
            clearAllLabel={t('common:list.clear_filters', 'Netejar filtres')}
            onClearAll={() => {
              setSearch('')
              setStatusFilter('all')
              setDocType('all')
              setExpiredOnly(false)
            }}
          />
        ) : null}

        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {!embedded && !clientId ? (
            <ClientFilterControl
              value={urlClientId}
              onChange={(id) => setUrlClientId(id)}
            />
          ) : null}
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_type', 'Tipus')}
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
              value={docType}
              onChange={(e) => setDocType(e.target.value as (typeof DOC_TYPES)[number])}
            >
              <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
              <option value="quote">{t('projects.commercial.type_quote', 'Pressupost')}</option>
              <option value="quote_amendment">
                {t('projects.commercial.type_amendment', 'Ampliació')}
              </option>
            </select>
          </label>

          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_status', 'Estat')}
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
              value={status}
              onChange={(e) =>
                setStatusFilter(e.target.value as (typeof STATUSES)[number])
              }
            >
              {STATUSES.map((s) => (
                <option key={s} value={s}>
                  {s === 'all'
                    ? t('projects.quotes.filter_all', 'Tots')
                    : statusLabel(s, t)}
                </option>
              ))}
            </select>
          </label>

          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_formalization', 'Formalització')}
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
              value={formalization}
              onChange={(e) => setFormalization(e.target.value as typeof formalization)}
            >
              <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
              <option value="signed_quote">{t('projects.commercial.badge_quote', 'Pressupost')}</option>
              <option value="separate_agreement">{t('projects.commercial.badge_formal_contract', 'Contracte formal')}</option>
            </select>
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_agreement', 'Acord')}
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
              value={hasAgreement}
              onChange={(e) => setHasAgreement(e.target.value as typeof hasAgreement)}
            >
              <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
              <option value="yes">{t('projects.quotes.filter_has_agreement', 'Amb acord')}</option>
              <option value="no">{t('projects.quotes.filter_no_agreement', 'Sense acord')}</option>
            </select>
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_signature', 'Firma de l’acord')}
            <select
              className="h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
              value={signature}
              onChange={(e) => setSignature(e.target.value as typeof signature)}
            >
              <option value="all">{t('projects.quotes.filter_all', 'Tots')}</option>
              <option value="none">{t('projects.quotes.filter_signature_none', 'Sense enviar')}</option>
              <option value="pending">{t('projects.commercial.badge_agreement_pending', 'Acord pendent de firma')}</option>
              <option value="signed">{t('projects.commercial.agreement_status_signed', 'Contracte signat')}</option>
            </select>
          </label>

          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_from', 'Des de')}
            <Input type="date" value={issuedFrom} onChange={(e) => setIssuedFrom(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_to', 'Fins a')}
            <Input type="date" value={issuedTo} onChange={(e) => setIssuedTo(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_total_min', 'Import min €')}
            <Input
              type="number"
              min="0"
              step="0.01"
              value={totalMin}
              onChange={(e) => setTotalMin(e.target.value)}
            />
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_total_max', 'Import max €')}
            <Input
              type="number"
              min="0"
              step="0.01"
              value={totalMax}
              onChange={(e) => setTotalMax(e.target.value)}
            />
          </label>
        </div>

        <label className="flex items-center gap-2 text-sm text-foreground">
          <input
            type="checkbox"
            checked={expiredOnly}
            onChange={(e) => setExpiredOnly(e.target.checked)}
          />
          {t('projects.quotes.filter_expired', 'Només caducats')}
        </label>
      </div>
  )

  const inspectedQuote =
    isSalesHub && !embedded
      ? (visibleHits.find((doc) => doc.id === inspectId) ?? null)
      : null

  const inspectedSentEvents =
    inspectedDetail?.events.filter((event) => event.event_type === 'sent') ?? []

  const salesInspector =
    inspectedQuote ? (
      <InspectorSheet
        title={`${quoteListTitle(inspectedQuote, t)} · ${inspectedQuote.client_display_name || t('projects.quotes.unknown_client', 'Client')}`}
        subtitle={
          inspectedQuote.client_display_name ||
          t('projects.quotes.unknown_client', 'Sense client')
        }
        badges={
          <>
            <CommercialDocumentStatusBadges doc={inspectedQuote} t={t} />
            <Badge variant="outline" className="text-[10px] font-normal">
              {quoteOriginLabel(inspectedQuote, t)}
            </Badge>
            <Badge variant="secondary" className="text-[10px]">
              {orderLinkLabel(inspectedQuote, t)}
            </Badge>
            <CommercialRelationshipBadges
              kinds={commercialRelationshipBadges({
                docType: inspectedQuote.doc_type,
                formalizationMode: inspectedQuote.formalization_mode,
                templateId: inspectedQuote.full_body_template_id,
                templateName: inspectedQuote.full_body_template_id
                  ? templateNameById.get(inspectedQuote.full_body_template_id)
                  : null,
                agreementStatus: agreementByQuote.get(inspectedQuote.id)?.status,
                versionStatus: agreementByQuote.get(inspectedQuote.id)?.versionStatus,
              })}
            />
          </>
        }
        fields={[
          {
            label: t('projects.commercial.total', 'Total'),
            value: `${moneyFmt.format(Number(inspectedQuote.total))} €`,
          },
          {
            label: t('projects.quotes.col_origin', 'Origen'),
            value: quoteOriginLabel(inspectedQuote, t),
          },
          {
            label: t('projects.quotes.col_order', 'Ordre'),
            value: orderLinkLabel(inspectedQuote, t),
          },
          {
            label: t('projects.collections.issued_on', 'Data'),
            value: (() => {
              const dateSource = inspectedQuote.issued_at ?? inspectedQuote.created_at
              return dateSource ? new Date(dateSource).toLocaleDateString('ca-ES') : '—'
            })(),
          },
        ]}
        onClose={() => setInspectId(null)}
        footer={
          <>
            <Button
              type="button"
              size="sm"
              onClick={() => void navigate(`/sales/quotes/${inspectedQuote.id}`)}
            >
              {t('common:list.open_record', 'Obrir fitxa')}
            </Button>
            {canSendQuote(inspectedQuote.status) ? (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => setShareDocId(inspectedQuote.id)}
              >
                {t('projects.commercial.send', 'Enviar')}
              </Button>
            ) : null}
          </>
        }
      >
        <section className="space-y-2 rounded-xl border border-border px-3 py-3">
          <p className="text-sm font-semibold text-foreground">
            {inspectedQuote.status === 'draft'
              ? t('projects.orphan.not_delivered', 'No entregat')
              : inspectedSentEvents.length > 0
                ? t('projects.orphan.delivered', 'Entregat')
                : t('projects.orphan.not_delivered', 'No entregat')}
          </p>
          {inspectedQuote.status === 'draft' ? (
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.quotes.inspector_draft_send_help',
                'Encara no s’ha emès. L’enviament al client es fa després d’emetre el pressupost.',
              )}
            </p>
          ) : inspectedDetailLoading ? (
            <p className="text-xs text-muted-foreground">
              {t('projects.commercial.share_loading', 'Carregant…')}
            </p>
          ) : inspectedSentEvents.length > 0 ? (
            <ul className="space-y-1 text-sm text-muted-foreground">
              {inspectedSentEvents.map((event) => {
                const payload = event.payload
                const recipient =
                  payload && typeof payload.recipient_masked === 'string'
                    ? payload.recipient_masked
                    : payload && typeof payload.recipient === 'string'
                      ? payload.recipient
                      : null
                return (
                  <li key={event.id}>
                    {deliveryChannelLabel(event.channel, t)}
                    {' · '}
                    {formatCommercialEventDate(event.occurred_at)}
                    {recipient ? ` · ${recipient}` : ''}
                  </li>
                )
              })}
            </ul>
          ) : (
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.not_delivered_help',
                'Encara no hi ha cap enviament ni cap sol·licitud de firma.',
              )}
            </p>
          )}
        </section>

        <section className="space-y-2">
          <p className="text-sm font-semibold text-foreground">
            {t('projects.orphan.journey_lines', 'Full de preus')}
          </p>
          {inspectedDetailLoading || !inspectedDetail ? (
            <p className="text-xs text-muted-foreground">
              {t('projects.commercial.share_loading', 'Carregant…')}
            </p>
          ) : inspectedDetail.lines.length === 0 ? (
            <p className="text-xs text-muted-foreground">
              {t('projects.quotes.inspector_empty_lines', 'Aquest pressupost encara no té línies.')}
            </p>
          ) : (
            <CommercialSummaryLines
              lines={inspectedDetail.lines}
              currency={inspectedDetail.currency || 'EUR'}
              showPrices={inspectedDetail.show_prices !== false}
              subtotal={Number(inspectedDetail.subtotal)}
              total={Number(inspectedDetail.total)}
            />
          )}
        </section>
      </InspectorSheet>
    ) : null

  const quoteColumns = useMemo<SalesDataTableColumn<CommercialDocumentSearchHit>[]>(
    () => [
      {
        id: 'doc',
        header: t('projects.quotes.title', 'Pressupostos'),
        cell: (doc) => {
          const numberLabel = quoteListNumberLabel(doc, t)
          return (
            <button
              type="button"
              className="text-left hover:underline"
              onClick={() => openView(doc.id)}
            >
              <span className="block font-semibold">{quoteListTitle(doc, t)}</span>
              {numberLabel ? (
                <span className="block text-xs font-normal text-muted-foreground">{numberLabel}</span>
              ) : null}
            </button>
          )
        },
      },
      ...(hideClientColumn
        ? []
        : [
            {
              id: 'client',
              header: t('projects.quotes.client', 'Client'),
              cell: (doc: CommercialDocumentSearchHit) => doc.client_display_name || '—',
            } satisfies SalesDataTableColumn<CommercialDocumentSearchHit>,
          ]),
      {
        id: 'origin',
        header: t('projects.quotes.col_origin', 'Origen'),
        cell: (doc) => (
          <Badge variant="outline" className="text-[10px] font-normal">
            {quoteOriginLabel(doc, t)}
          </Badge>
        ),
      },
      {
        id: 'order',
        header: t('projects.quotes.col_order', 'Ordre'),
        cell: (doc) => {
          if (doc.project_id) {
            return (
              <Link
                to={`${projectBase}/${doc.project_id}`}
                className="text-indigo-600 hover:underline"
                onClick={(e) => e.stopPropagation()}
              >
                {orderLinkLabel(doc, t)}
              </Link>
            )
          }
          return (
            <Badge variant="secondary" className="text-[10px]">
              {orderLinkLabel(doc, t)}
            </Badge>
          )
        },
      },
      {
        id: 'status',
        header: t('projects.quotes.filter_status', 'Estat'),
        cell: (doc) => <CommercialDocumentStatusBadges doc={doc} t={t} />,
      },
      {
        id: 'total',
        header: t('projects.commercial.total', 'Total'),
        className: 'text-right tabular-nums',
        cell: (doc) => `${moneyFmt.format(Number(doc.total))} €`,
      },
      {
        id: 'date',
        header: t('projects.collections.issued_on', 'Data'),
        cell: (doc) => {
          const dateSource = doc.issued_at ?? doc.created_at
          return dateSource ? new Date(dateSource).toLocaleDateString('ca-ES') : '—'
        },
      },
    ],
    [hideClientColumn, projectBase, t],
  )

  const results = (
    <div className="space-y-4">
      {isLoading && (
        <p className="text-sm text-muted-foreground">
          {t('projects.quotes.loading', 'Carregant…')}
        </p>
      )}
      {error && (
        <p className="text-sm text-destructive">
          {t('projects.quotes.load_failed', 'No s’han pogut carregar els documents')}
        </p>
      )}
      {!isLoading && !error && visibleHits.length === 0 && (
        <p className="rounded-2xl border border-dashed border-border p-6 text-center text-sm text-muted-foreground">
          {prospectOrders.length > 0
            ? t(
                'projects.quotes.empty_but_prospects',
                'Encara no hi ha pressupostos emesos. Continua amb una ordre en preparació de dalt.',
              )
            : t('projects.quotes.empty', 'Cap document no coincideix amb la cerca.')}
        </p>
      )}

      {visibleHits.length > 0 && useSharedList && viewMode === 'cards' ? (
        <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {visibleHits.map((doc) => {
            const agreement = agreementByQuote.get(doc.id)
            const tone =
              doc.status === 'accepted' || doc.status === 'signed'
                ? 'paid'
                : doc.status === 'issued'
                  ? 'pending'
                  : doc.status === 'rejected' || doc.status === 'cancelled'
                    ? 'danger'
                    : doc.status === 'draft'
                      ? 'draft'
                      : 'neutral'
            const numberLabel = quoteListNumberLabel(doc, t)
            return (
              <li key={doc.id}>
                <SalesDocCard
                  title={
                    <button
                      type="button"
                      className="text-left hover:underline"
                      onClick={(e) => {
                        e.stopPropagation()
                        openView(doc.id)
                      }}
                    >
                      {hideClientColumn
                        ? quoteListTitle(doc, t)
                        : `${quoteListTitle(doc, t)} · ${doc.client_display_name || t('projects.quotes.unknown_client', 'Client')}`}
                    </button>
                  }
                  subtitle={numberLabel ?? orderLinkLabel(doc, t)}
                  amount={`${moneyFmt.format(Number(doc.total))} €`}
                  tone={tone}
                  onClick={() => openInspect(doc.id)}
                  active={inspectId === doc.id}
                  badges={
                    <>
                      <CommercialDocumentStatusBadges doc={doc} t={t} />
                      <Badge variant="outline" className="text-[10px] font-normal">
                        {quoteOriginLabel(doc, t)}
                      </Badge>
                      <Badge variant="secondary" className="text-[10px]">
                        {orderLinkLabel(doc, t)}
                      </Badge>
                      <CommercialRelationshipBadges
                        kinds={commercialRelationshipBadges({
                          docType: doc.doc_type,
                          formalizationMode: doc.formalization_mode,
                          templateId: doc.full_body_template_id,
                          templateName: doc.full_body_template_id
                            ? templateNameById.get(doc.full_body_template_id)
                            : null,
                          agreementStatus: agreement?.status,
                          versionStatus: agreement?.versionStatus,
                        })}
                      />
                    </>
                  }
                  meta={
                    <>
                      {lineNames.get(doc.id) ? `${lineNames.get(doc.id)} · ` : null}
                      {doc.project_name || orderLinkLabel(doc, t)}
                    </>
                  }
                  footer={
                    <div className="flex flex-wrap gap-2">
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        onClick={(e) => {
                          e.stopPropagation()
                          openView(doc.id)
                        }}
                      >
                        {t('common:list.open_record', 'Obrir fitxa')}
                      </Button>
                      {canSendQuote(doc.status) ? (
                        <Button
                          type="button"
                          size="sm"
                          variant="outline"
                          onClick={(e) => {
                            e.stopPropagation()
                            setShareDocId(doc.id)
                          }}
                        >
                          {t('projects.commercial.send', 'Enviar')}
                        </Button>
                      ) : null}
                    </div>
                  }
                />
              </li>
            )
          })}
        </ul>
      ) : null}

      {!useSharedList && visibleHits.length > 0 ? (
        <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card">
          {visibleHits.map((doc) => {
            const agreement = agreementByQuote.get(doc.id)
            return (
              <QuoteRow
                key={doc.id}
                doc={doc}
                lineName={lineNames.get(doc.id) ?? null}
                paidCents={accountedPaidCents(doc, hits, payments)}
                projectBase={projectBase}
                badges={commercialRelationshipBadges({
                  docType: doc.doc_type,
                  formalizationMode: doc.formalization_mode,
                  templateId: doc.full_body_template_id,
                  templateName: doc.full_body_template_id
                    ? templateNameById.get(doc.full_body_template_id)
                    : null,
                  agreementStatus: agreement?.status,
                  versionStatus: agreement?.versionStatus,
                })}
                onView={openView}
                onShare={setShareDocId}
                onDuplicate={
                  isCommercialQuoteReissuable(doc)
                    ? () => setReissueDocId(doc.id)
                    : undefined
                }
              />
            )
          })}
        </ul>
      ) : null}

      {useSharedList && visibleHits.length > 0 && viewMode === 'table' ? (
        <SalesDataTable
          columns={quoteColumns}
          rows={visibleHits}
          getRowId={(doc) => doc.id}
          density={density}
          activeRowId={inspectId}
          onRowActivate={(doc) => openInspect(doc.id)}
          countLabel={t('common:list.showing_count', 'Mostrant {{shown}} de {{total}}', {
            shown: visibleHits.length,
            total: visibleHits.length,
          })}
          rowActions={(doc) => [
            {
              key: 'open',
              label: t('common:list.open_record', 'Obrir fitxa'),
              onSelect: () => openView(doc.id),
            },
            ...(canSendQuote(doc.status)
              ? [
                  {
                    key: 'send',
                    label: t('projects.commercial.send', 'Enviar'),
                    onSelect: () => setShareDocId(doc.id),
                  },
                ]
              : []),
          ]}
        />
      ) : null}
    </div>
  )

  const dialogs = (
    <>
      <CreateQuoteWizardDialog
        open={wizardOpen}
        onOpenChange={(next) => {
          setWizardOpen(next)
          if (!next) setWizardInitialType(null)
        }}
        clientId={clientId ?? null}
        clientName={clientName ?? null}
        initialType={wizardInitialType}
      />

      <ReissueQuoteDialog
        open={!!reissueDocId}
        busy={reissueBusy}
        onOpenChange={(open) => {
          if (!open && !reissueBusy) setReissueDocId(null)
        }}
        onConfirm={() => void confirmReissue()}
        title={t('projects.quotes.duplicate_title', 'Duplicar pressupost?')}
        help={t(
          'projects.quotes.duplicate_help',
          'L’anterior es conserva a l’historial. El nou usarà els preus actuals de l’ordre i quedarà pendent de resposta.',
        )}
        confirmLabel={t('projects.quotes.duplicate_confirm', 'Duplicar')}
      />

      {viewDocId && (
        <CommercialDocumentView
          documentId={viewDocId}
          open={!!viewDocId}
          onClose={closeView}
          onChanged={handleChanged}
          onShare={() => {
            setShareDocId(viewDocId)
          }}
        />
      )}
      {shareDocId && (
        <CommercialDocumentShareSheet
          documentId={shareDocId}
          open={!!shareDocId}
          onClose={() => setShareDocId(null)}
        />
      )}
    </>
  )

  if (viewParam) {
    return <Navigate to={`/sales/quotes/${viewParam}`} replace />
  }

  if (isSalesHub) {
    return (
      <>
        <PageShell
          bare
          toolbar={quoteToolbar}
          inspector={salesInspector}
          inspectorOpen={Boolean(inspectId)}
          onInspectorClose={() => setInspectId(null)}
        >
          {results}
        </PageShell>
        {dialogs}
      </>
    )
  }

  return (
    <div className={embedded ? 'space-y-5' : 'mx-auto max-w-4xl space-y-5 px-4 py-6'}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          {embedded ? (
            <>
              <p className="text-sm text-muted-foreground">
                {clientName
                  ? t('projects.quotes.scoped_subtitle', 'Documents comercials de {{name}}', {
                      name: clientName,
                    })
                  : t(
                      'projects.quotes.scoped_subtitle_generic',
                      'Documents comercials d’aquest client',
                    )}
              </p>
              <Link to={globalQuotesHref} className="text-sm text-indigo-600 hover:underline">
                {t('projects.quotes.see_all_global', 'Veure tots els pressupostos')}
              </Link>
            </>
          ) : (
            <>
              <h1 className="text-2xl font-bold text-foreground">
                {t('projects.quotes.title', 'Pressupostos')}
              </h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {t(
                  'projects.quotes.subtitle',
                  'Cerca pressupostos i ampliacions per client, número o text de línia.',
                )}
              </p>
              <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1">
                <Link to="/delivery-notes" className="text-sm text-indigo-600 hover:underline">
                  {t('projects.collections.title', 'Albarans')}
                </Link>
                <Link to="/sales/agreements" className="text-sm text-indigo-600 hover:underline">
                  {t('projects.agreements.open', 'Acords comercials')}
                </Link>
                <Link to={QUOTE_TEMPLATES_HREF} className="text-sm text-indigo-600 hover:underline">
                  {t('projects.quotes.templates_link', 'Plantilles de pressupost')}
                </Link>
                <Link
                  to={commercialTemplatesHref('quote', { create: true })}
                  className="text-sm text-indigo-600 hover:underline"
                >
                  {t('projects.quotes.templates_new', 'Nova plantilla')}
                </Link>
              </div>
            </>
          )}
        </div>
      </div>
      {quoteToolbar}
      {results}
      {dialogs}
    </div>
  )
}

function QuoteRow({
  doc,
  lineName,
  paidCents,
  projectBase,
  badges,
  onView,
  onShare,
  onDuplicate,
}: {
  doc: CommercialDocumentSearchHit
  lineName: string | null
  paidCents: number
  projectBase: string
  badges: ReturnType<typeof commercialRelationshipBadges>
  onView: (id: string) => void
  onShare: (id: string) => void
  onDuplicate?: () => void
}) {
  const { t } = useTranslation('projects')
  const dateSource = doc.issued_at ?? doc.created_at
  const dateText = dateSource
    ? new Date(dateSource).toLocaleDateString('ca-ES', {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
      })
    : '—'

  return (
    <li className="flex flex-col gap-3 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0 space-y-1">
        <p className="text-sm font-medium text-foreground">
          {quoteListTitle(doc, t)}
        </p>
        {quoteListNumberLabel(doc, t) ? (
          <p className="text-sm text-muted-foreground truncate">{quoteListNumberLabel(doc, t)}</p>
        ) : null}
        {lineName ? (
          <p className="text-sm text-muted-foreground truncate">{lineName}</p>
        ) : null}
        <p className="text-sm text-muted-foreground truncate">
          {doc.client_id ? (
            <Link
              to={`/contacts/${doc.client_id}`}
              className="text-indigo-600 hover:underline"
              aria-label={t('projects.commercial.open_contact', 'Obrir fitxa del client')}
            >
              {doc.client_display_name || t('projects.quotes.unknown_client', 'Client')}
            </Link>
          ) : (
            doc.client_display_name || t('projects.quotes.unknown_client', 'Client')
          )}
          {` · ${orderLinkLabel(doc, t)}`}
        </p>
        <div className="flex flex-wrap items-center gap-1.5">
          <CommercialDocumentStatusBadges doc={doc} paidCents={paidCents} t={t} />
          <CommercialRelationshipBadges kinds={badges} />
          <span className="text-xs text-muted-foreground tabular-nums">{dateText}</span>
        </div>
        {doc.project_id && (
          <Link
            to={`${projectBase}/${doc.project_id}`}
            className="text-xs text-indigo-600 hover:underline"
          >
            {t('projects.quotes.open_order', 'Obrir ordre')}
          </Link>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-2 shrink-0">
        <span className="text-sm font-semibold tabular-nums">
          {moneyFmt.format(Number(doc.total))} €
        </span>
        <Button type="button" size="sm" variant="outline" onClick={() => onView(doc.id)}>
          {t('projects.commercial.view', 'Veure')}
        </Button>
        {canSendQuote(doc.status) ? (
          <Button type="button" size="sm" variant="outline" onClick={() => onShare(doc.id)}>
            {t('projects.commercial.send', 'Enviar')}
          </Button>
        ) : null}
        {onDuplicate ? (
          <Button type="button" size="sm" variant="outline" onClick={onDuplicate}>
            {t('projects.quotes.duplicate', 'Duplicar')}
          </Button>
        ) : null}
      </div>
    </li>
  )
}
