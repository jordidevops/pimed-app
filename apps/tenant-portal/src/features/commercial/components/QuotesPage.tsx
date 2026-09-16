import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import {
  listPaymentsForDocuments,
  reissueCommercialQuote,
  searchCommercialDocuments,
  type CommercialDocument,
  type CommercialDocumentSearchHit,
} from '../api/commercialFlowService'
import { accountedPaidCents } from '../utils/paymentAllocation'
import { isCommercialQuoteReissuable } from '../utils/pendingCommercialAction'
import { CommercialDocumentShareSheet } from './CommercialDocumentShareSheet'
import { CommercialDocumentView } from './CommercialDocumentView'
import { CommercialDocumentStatusBadges } from './CommercialDocumentStatusBadge'
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
  'delivery_note',
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

export function QuotesPage() {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const isFieldService = useIsFieldService()
  const projectBase = isFieldService ? '/field/orders' : '/projects'
  const [searchParams, setSearchParams] = useSearchParams()

  const [search, setSearch] = useState('')
  const debouncedSearch = useDebouncedValue(search, 250)
  const [docType, setDocType] = useState<(typeof DOC_TYPES)[number]>('all')
  const [status, setStatus] = useState<(typeof STATUSES)[number]>('all')
  const [issuedFrom, setIssuedFrom] = useState('')
  const [issuedTo, setIssuedTo] = useState('')
  const [expiredOnly, setExpiredOnly] = useState(false)
  const [totalMin, setTotalMin] = useState('')
  const [totalMax, setTotalMax] = useState('')
  const [viewDocId, setViewDocId] = useState<string | null>(null)
  const [shareDocId, setShareDocId] = useState<string | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [reissueDocId, setReissueDocId] = useState<string | null>(null)
  const [reissueBusy, setReissueBusy] = useState(false)

  useEffect(() => {
    const view = searchParams.get('view')
    if (view) setViewDocId(view)
  }, [searchParams])

  function closeView() {
    setViewDocId(null)
    if (!searchParams.get('view')) return
    const next = new URLSearchParams(searchParams)
    next.delete('view')
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
    ],
  )

  const { data: hits = [], isLoading, error } = useQuery({
    queryKey: ['commercial_documents', 'search', filters],
    queryFn: () => searchCommercialDocuments(filters),
  })

  const docIds = useMemo(() => hits.map((d) => d.id), [hits])

  const { data: payments = [] } = useQuery({
    queryKey: ['commercial_payments', 'quotes-search', docIds.join(',')],
    queryFn: () => listPaymentsForDocuments(docIds),
    enabled: docIds.length > 0,
  })

  function handleChanged() {
    void queryClient.invalidateQueries({ queryKey: ['commercial_documents', 'search'] })
    void queryClient.invalidateQueries({ queryKey: ['commercial_payments', 'quotes-search'] })
  }

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

  return (
    <div className="mx-auto max-w-4xl space-y-5 px-4 py-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-foreground">
            {t('projects.quotes.title', 'Pressupostos')}
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            {t(
              'projects.quotes.subtitle',
              'Cerca pressupostos, ampliacions i albarans per client, número o text de línia.',
            )}
          </p>
        </div>
        <Button type="button" className="shrink-0" onClick={() => setCreateOpen(true)}>
          <Plus className="mr-1.5 h-4 w-4" aria-hidden />
          {t('projects.quotes.create', 'Nou pressupost')}
        </Button>
      </div>

      <div className="space-y-3 rounded-2xl border border-border bg-card p-4">
        <label className="relative block">
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

        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
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
              <option value="delivery_note">
                {t('projects.commercial.type_delivery', 'Albarà')}
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

          <label className="flex items-center gap-2 text-sm text-foreground pt-5">
            <input
              type="checkbox"
              checked={expiredOnly}
              onChange={(e) => setExpiredOnly(e.target.checked)}
            />
            {t('projects.quotes.filter_expired', 'Només caducats')}
          </label>

          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_from', 'Des de')}
            <Input type="date" value={issuedFrom} onChange={(e) => setIssuedFrom(e.target.value)} />
          </label>
          <label className="flex flex-col gap-1 text-xs text-muted-foreground">
            {t('projects.quotes.filter_to', 'Fins a')}
            <Input type="date" value={issuedTo} onChange={(e) => setIssuedTo(e.target.value)} />
          </label>
          <div className="grid grid-cols-2 gap-2">
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
        </div>
      </div>

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
      {!isLoading && !error && hits.length === 0 && (
        <p className="text-sm text-muted-foreground rounded-2xl border border-dashed border-border p-6 text-center">
          {t('projects.quotes.empty', 'Cap document no coincideix amb la cerca.')}
        </p>
      )}

      {hits.length > 0 && (
        <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card">
          {hits.map((doc) => (
            <QuoteRow
              key={doc.id}
              doc={doc}
              paidCents={accountedPaidCents(doc, hits, payments)}
              projectBase={projectBase}
              onView={setViewDocId}
              onShare={setShareDocId}
              onDuplicate={
                isCommercialQuoteReissuable(doc)
                  ? () => setReissueDocId(doc.id)
                  : undefined
              }
            />
          ))}
        </ul>
      )}

      <CreateQuoteDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
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
    </div>
  )
}

function QuoteRow({
  doc,
  paidCents,
  projectBase,
  onView,
  onShare,
  onDuplicate,
}: {
  doc: CommercialDocumentSearchHit
  paidCents: number
  projectBase: string
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
        <p className="text-sm text-muted-foreground truncate">
          {doc.client_display_name || t('projects.quotes.unknown_client', 'Client')}
          {doc.project_name ? ` · ${doc.project_name}` : ''}
        </p>
        <div className="flex flex-wrap items-center gap-1.5">
          <CommercialDocumentStatusBadges doc={doc} paidCents={paidCents} t={t} />
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
