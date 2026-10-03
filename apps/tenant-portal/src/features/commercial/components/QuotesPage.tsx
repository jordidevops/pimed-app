import { useEffect, useMemo, useState } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { PageShell } from '@/components/layout/PageShell'
import { ListViewToggle } from '@/components/layout/ListViewToggle'
import { FilterChips } from '@/components/layout/FilterChips'
import { useListViewMode } from '@/hooks/useListViewMode'
import { useListDensity } from '@/hooks/useListDensity'
import { SalesDocCard } from './SalesDocCard'
import { useToast } from '@/hooks/use-toast'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { SalesDataTable, type SalesDataTableColumn } from './SalesDataTable'
import {
  listPaymentsForDocuments,
  listPrimaryLineNames,
  listQuoteAgreementStates,
  listCommercialDocumentsForClient,
  reissueCommercialQuote,
  searchCommercialDocuments,
  type CommercialDocument,
  type CommercialDocumentSearchHit,
  type QuoteAgreementState,
} from '../api/commercialFlowService'
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
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentView } from './CommercialDocumentView'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
import { CommercialRelationshipBadges } from './CommercialRelationshipBadges'
import { CreateQuoteDialog } from './CreateQuoteDialog'
import { ReissueQuoteDialog } from './ReissueQuoteDialog'

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
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const isFieldService = useIsFieldService()
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const location = useLocation()
  const isSalesHub = location.pathname.startsWith('/sales')
  const [searchParams, setSearchParams] = useSearchParams()
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
  const [shareDocId, setShareDocId] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [reissueDocId, setReissueDocId] = useState<string | null>(null)
  const [reissueBusy, setReissueBusy] = useState(false)

  const urlClientId = !embedded && !clientId
    ? (searchParams.get('client_id')?.trim() || null)
    : null

  function setUrlClientId(nextId: string | null) {
    if (embedded || clientId) return
    const next = new URLSearchParams(searchParams)
    if (nextId) next.set('client_id', nextId)
    else next.delete('client_id')
    setSearchParams(next, { replace: true })
  }

  useEffect(() => {
    if (embedded) return
    const view = searchParams.get('view')
    if (view) setViewDocId(view)
  }, [searchParams, embedded])

  useEffect(() => {
    if (embedded || clientId) return
    const q = searchParams.get('q')
    if (q && !search) setSearch(q)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const next = searchParams.get('status')
    if (next && STATUSES.includes(next as (typeof STATUSES)[number])) {
      setStatus(next as (typeof STATUSES)[number])
    }
  }, [searchParams])

  function closeView() {
    setViewDocId(null)
    if (embedded || !searchParams.get('view')) return
    const next = new URLSearchParams(searchParams)
    next.delete('view')
    setSearchParams(next, { replace: true })
  }

  function openView(id: string) {
    setViewDocId(id)
    if (embedded) return
    const next = new URLSearchParams(searchParams)
    next.set('view', id)
    setSearchParams(next, { replace: true })
  }

  const filters = useMemo(
    () => ({
      q: debouncedSearch,
      docTypes: docType === 'all' ? null : [docType],
      statuses: status === 'all' ? null : [status],
      issuedFrom: issuedFrom ? new Date(issuedFrom).toISOString() : null,
      issuedTo: issuedTo ? new Date(`${issuedTo}T23:59:59`).toISOString() : null,
      expiredOnly,
      totalMin: totalMin === '' ? null : Number(totalMin),
      totalMax: totalMax === '' ? null : Number(totalMax),
      limit: 100,
      clientId: urlClientId,
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
      urlClientId,
    ],
  )

  const { data: globalHits = [], isLoading: globalLoading, error: globalError } = useQuery({
    queryKey: ['commercial_documents', 'search', filters],
    queryFn: () => searchCommercialDocuments(filters),
    enabled: !clientId,
  })

  const { data: clientDocs = [], isLoading: clientLoading, error: clientError } = useQuery({
    queryKey: ['commercial_documents', 'client', clientId],
    queryFn: () => listCommercialDocumentsForClient(clientId!),
    enabled: !!clientId,
  })

  const hits: CommercialDocumentSearchHit[] = useMemo(() => {
    if (!clientId) return globalHits
    const q = debouncedSearch.trim().toLowerCase()
    return clientDocs
      .filter((doc) => {
        if (doc.doc_type === 'delivery_note') return false
        if (docType !== 'all' && doc.doc_type !== docType) return false
        if (status !== 'all' && doc.status !== status) return false
        if (expiredOnly) {
          if (!doc.valid_until || new Date(doc.valid_until) >= new Date()) return false
        }
        if (issuedFrom) {
          const from = new Date(issuedFrom).getTime()
          const issued = doc.issued_at ? new Date(doc.issued_at).getTime() : 0
          if (issued < from) return false
        }
        if (issuedTo) {
          const to = new Date(`${issuedTo}T23:59:59`).getTime()
          const issued = doc.issued_at ? new Date(doc.issued_at).getTime() : 0
          if (issued > to) return false
        }
        if (totalMin !== '' && Number(doc.total) < Number(totalMin)) return false
        if (totalMax !== '' && Number(doc.total) > Number(totalMax)) return false
        if (q) {
          const hay = [
            doc.doc_number,
            doc.status,
            clientName,
          ]
            .filter(Boolean)
            .join(' ')
            .toLowerCase()
          if (!hay.includes(q)) return false
        }
        return true
      })
      .map((doc) => ({
        ...doc,
        client_display_name: clientName ?? null,
        project_name: null,
      }))
  }, [
    clientDocs,
    clientId,
    clientName,
    debouncedSearch,
    docType,
    expiredOnly,
    globalHits,
    issuedFrom,
    issuedTo,
    status,
    totalMax,
    totalMin,
  ])

  const isLoading = clientId ? clientLoading : globalLoading
  const error = clientId ? clientError : globalError

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
            onRemove: () => setStatus('all'),
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

  const quoteToolbar = (
      <div className={isSalesHub ? 'space-y-3' : 'space-y-3 rounded-2xl border border-border bg-card p-4'}>
        <div className="flex flex-wrap items-center gap-2">
          <label className="relative block min-w-[12rem] flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              className="pl-9"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder={t(
                'projects.quotes.search_placeholder',
                'Client, número, OS o text de línia…',
              )}
              aria-label={t('projects.quotes.search_aria', 'Cerca documents comercials')}
            />
          </label>
          {isSalesHub ? (
            <ListViewToggle
              mode={listMode}
              onModeChange={setListMode}
              density={density}
              onDensityChange={setDensity}
              showDensity={effectiveMode === 'table'}
            />
          ) : null}
          <Button type="button" className="shrink-0" onClick={() => setCreateOpen(true)}>
            <Plus className="mr-1.5 h-4 w-4" aria-hidden />
            {t('projects.quotes.create', 'Nou pressupost')}
          </Button>
        </div>
        {isSalesHub ? (
          <FilterChips
            chips={quoteFilterChips}
            clearAllLabel={t('common:list.clear_filters', 'Netejar filtres')}
            onClearAll={() => {
              setSearch('')
              setStatus('all')
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
              onChange={(e) => setStatus(e.target.value as (typeof STATUSES)[number])}
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

  const quoteColumns = useMemo<SalesDataTableColumn<CommercialDocumentSearchHit>[]>(
    () => [
      {
        id: 'doc',
        header: t('projects.quotes.title', 'Pressupostos'),
        cell: (doc) => (
          <button type="button" className="font-semibold hover:underline" onClick={() => openView(doc.id)}>
            {docTypeLabel(doc.doc_type, t)} {doc.doc_number ?? '—'}
          </button>
        ),
      },
      {
        id: 'client',
        header: t('projects.quotes.client', 'Client'),
        cell: (doc) => doc.client_display_name || '—',
      },
      {
        id: 'status',
        header: t('projects.quotes.filter_status', 'Estat'),
        cell: (doc) => <Badge variant="outline">{statusLabel(doc.status, t)}</Badge>,
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
    [t],
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
          {t('projects.quotes.empty', 'Cap document no coincideix amb la cerca.')}
        </p>
      )}

      {visibleHits.length > 0 && isSalesHub && effectiveMode === 'cards' ? (
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
            return (
              <li key={doc.id}>
                <SalesDocCard
                  title={`${docTypeLabel(doc.doc_type, t)} ${doc.doc_number ?? '—'}`}
                  subtitle={doc.client_display_name || t('projects.quotes.unknown_client', 'Client')}
                  amount={`${moneyFmt.format(Number(doc.total))} €`}
                  tone={tone}
                  onClick={() => openView(doc.id)}
                  badges={
                    <>
                      <Badge variant="outline">{statusLabel(doc.status, t)}</Badge>
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
                      {doc.project_name || '—'}
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
                        {t('projects.commercial.view', 'Veure')}
                      </Button>
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
                    </div>
                  }
                />
              </li>
            )
          })}
        </ul>
      ) : null}

      {visibleHits.length > 0 && !isSalesHub ? (
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

      {isSalesHub && visibleHits.length > 0 && effectiveMode === 'table' ? (
        <SalesDataTable
          columns={quoteColumns}
          rows={visibleHits}
          getRowId={(doc) => doc.id}
          density={density}
          onRowActivate={(doc) => openView(doc.id)}
          countLabel={t('common:list.showing_count', 'Mostrant {{shown}} de {{total}}', {
            shown: visibleHits.length,
            total: visibleHits.length,
          })}
          rowActions={(doc) => [
            {
              key: 'view',
              label: t('projects.commercial.view', 'Veure'),
              onSelect: () => openView(doc.id),
            },
            {
              key: 'send',
              label: t('projects.commercial.send', 'Enviar'),
              onSelect: () => setShareDocId(doc.id),
            },
          ]}
        />
      ) : null}
    </div>
  )

  const dialogs = (
    <>
      <CreateQuoteDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        clientId={clientId ?? urlClientId}
        clientName={clientName}
        onCreated={(documentId) => {
          handleChanged()
          setViewDocId(documentId)
          toast({
            title: t('projects.commercial.quote_issued', 'Pressupost emès'),
          })
        }}
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

  if (isSalesHub) {
    return (
      <>
        <PageShell bare toolbar={quoteToolbar}>
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
                <Link to="/agreements" className="text-sm text-indigo-600 hover:underline">
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
          {docTypeLabel(doc.doc_type, t)} {doc.doc_number ?? '—'}
        </p>
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
          {doc.project_name ? ` · ${doc.project_name}` : ''}
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
        <Button type="button" size="sm" variant="outline" onClick={() => onShare(doc.id)}>
          {t('projects.commercial.send', 'Enviar')}
        </Button>
        {onDuplicate ? (
          <Button type="button" size="sm" variant="outline" onClick={onDuplicate}>
            {t('projects.quotes.duplicate', 'Duplicar')}
          </Button>
        ) : null}
      </div>
    </li>
  )
}
