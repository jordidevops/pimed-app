import { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight, RefreshCw, Search, FileSignature, FileText } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useSigningSubmissions, SUBMISSIONS_PAGE_SIZE } from '../api/useSigningSubmissions'
import { useSigningSubmissionsRealtime } from '../api/useSigningSubmissionsRealtime'
import { SIGNING_STATUS_CLASSES } from '../signingStatusColors'
import { DocumentsSubNav } from '@/features/documents/components/DocumentsSubNav'
import type { SigningStatus } from '../api/signingService'
import { getSigningProvider } from '../api/signingService'
import type { SigningSubmissionListItem, SubmissionsFilter } from '../api/useSigningSubmissions'
import { useCommercialSigningHubBySubmissions } from '@/features/commercial/api/useCommercialSigningHub'
import {
  commercialQuoteViewHref,
  commercialSigningHubTitle,
  matchesSigningCenterSearch,
} from '@/features/commercial/utils/commercialSigningHub'

// ─── Status badge ─────────────────────────────────────────────────────────────

function StatusBadge({ status, label }: { status: SigningStatus | null; label: string }) {
  if (!status) return null
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${SIGNING_STATUS_CLASSES[status]}`}>
      {label}
    </span>
  )
}

// ─── Filter pills ─────────────────────────────────────────────────────────────

const ALL_STATUSES: SigningStatus[] = [
  'draft', 'pending', 'in_progress', 'completed', 'declined', 'expired', 'cancelled', 'error',
]

// ─── Source type label ────────────────────────────────────────────────────────

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString('ca-ES', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}

function signersSummary(signers: unknown): string {
  if (!Array.isArray(signers) || signers.length === 0) return '—'
  const first = signers[0] as { email?: string; name?: string }
  const rest  = signers.length - 1
  const label = first.name || first.email || '?'
  return rest > 0 ? `${label} +${rest}` : label
}

// ─── Main component ────────────────────────────────────────────────────────────

export function SigningCenterPage() {
  const { t }    = useTranslation('signing')
  const { t: tDocuments } = useTranslation('documents')
  const navigate = useNavigate()
  const { toast } = useToast()
  const { activeTenant, selectedTenantId } = useTenant()
  const tenantId = selectedTenantId ?? activeTenant?.id ?? ''

  const [page,    setPage]    = useState(0)
  const [search,  setSearch]  = useState('')
  const [filters, setFilters] = useState<SubmissionsFilter>({})

  const { data: result, isLoading, refetch } = useSigningSubmissions(tenantId || undefined, filters, page)

  useSigningSubmissionsRealtime(tenantId || undefined, (event) => {
    const statusLabel = t(`center.status.${event.status}`, event.status)
    toast({
      title:       t('center.realtimeAlert', 'Canvi d\'estat de signatura'),
      description: `${t('center.submission', 'Submissió')} → ${statusLabel}`,
      variant:     event.status === 'error' || event.status === 'declined' ? 'destructive' : 'default',
    })
  })

  const rows: SigningSubmissionListItem[] = result?.data ?? []
  const total    = result?.total ?? 0
  const pageSize = result?.pageSize ?? SUBMISSIONS_PAGE_SIZE
  const totalPages = Math.max(1, Math.ceil(total / pageSize))
  const { data: commercialHub = {} } = useCommercialSigningHubBySubmissions(
    rows.map((row) => row.id).filter((id): id is string => !!id),
  )

  const filteredRows = search.trim()
    ? rows.filter(r => matchesSigningCenterSearch(r, search))
    : rows

  function toggleStatusFilter(s: SigningStatus) {
    setFilters(prev => ({ ...prev, status: prev.status === s ? undefined : s }))
    setPage(0)
  }

  function setSourceFilter(v: string) {
    setFilters(prev => ({
      ...prev,
      source_type: v ? (v as SubmissionsFilter['source_type']) : undefined,
    }))
    setPage(0)
  }

  function setProviderFilter(v: string) {
    setFilters(prev => ({
      ...prev,
      signing_provider: v ? (v as SubmissionsFilter['signing_provider']) : undefined,
    }))
    setPage(0)
  }

  function commercialSourceLabel(docType: string): string {
    if (docType === 'delivery_note') return t('center.sourceDeliveryNote', 'Albarà')
    if (docType === 'quote_amendment') return t('center.sourceAmendment', 'Ampliació')
    return t('center.sourceQuote', 'Pressupost')
  }

  return (
    <div className="p-6 space-y-6">
      <div className="flex items-center gap-2">
        <FileText className="h-6 w-6 text-primary" />
        <h1 className="text-xl font-semibold">{tDocuments('page.title', 'Documents')}</h1>
      </div>

      {/* Sub-navegació */}
      <DocumentsSubNav />

      <div className="max-w-6xl mx-auto space-y-6">

      {/* Header */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div>
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <FileSignature className="h-5 w-5 text-indigo-500" />
            {t('center.title', 'Centre de signatures')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('center.subtitle', 'Seguiment de totes les sol·licituds de signatura')}
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => refetch()}>
          <RefreshCw className="h-4 w-4 mr-1.5" />
          {t('center.refresh', 'Actualitzar')}
        </Button>
      </div>

      {/* Filters */}
      <div className="space-y-3">
        {/* Status pills */}
        <div className="flex flex-wrap gap-1.5">
          <button
            onClick={() => { setFilters(prev => ({ ...prev, status: undefined })); setPage(0) }}
            className={`px-3 py-1 rounded-full text-xs font-medium border transition-colors ${
              !filters.status ? 'bg-foreground text-background border-foreground' : 'border-border hover:bg-accent'
            }`}
          >
            {t('center.statusAll', 'Tots')}
          </button>
          {ALL_STATUSES.map(s => (
            <button
              key={s}
              onClick={() => toggleStatusFilter(s)}
              className={`px-3 py-1 rounded-full text-xs font-medium border transition-colors ${
                filters.status === s ? 'bg-foreground text-background border-foreground' : 'border-border hover:bg-accent'
              }`}
            >
              {t(`center.status.${s}`, s)}
            </button>
          ))}
        </div>

        {/* Row 2: source type + date + search */}
        <div className="flex flex-wrap gap-2 items-center">
          <select
            title={t('center.filterSource', 'Origen')}
            value={filters.source_type ?? ''}
            onChange={e => setSourceFilter(e.target.value)}
            className="h-8 text-sm border border-input rounded-md px-2 bg-background"
          >
            <option value="">{t('center.sourceAll', 'Tots els orígens')}</option>
            <option value="document_existing">{t('center.sourceDocument', 'Document existent')}</option>
            <option value="template_locale">{t('center.sourceTemplate', 'Plantilla')}</option>
          </select>

          <select
            title={t('center.filterProvider', 'Proveïdor')}
            value={filters.signing_provider ?? ''}
            onChange={e => setProviderFilter(e.target.value)}
            className="h-8 text-sm border border-input rounded-md px-2 bg-background"
          >
            <option value="">{t('center.providerAll', 'Tots els proveïdors')}</option>
            <option value="native">{t('center.providerNative', 'Firma pròpia')}</option>
            <option value="docuseal">{t('center.providerDocuseal', 'DocuSeal')}</option>
          </select>

          <input
            type="date"
            title={t('center.filterFrom', 'Des de')}
            value={filters.date_from ?? ''}
            onChange={e => { setFilters(prev => ({ ...prev, date_from: e.target.value || undefined })); setPage(0) }}
            className="h-8 text-sm border border-input rounded-md px-2 bg-background"
          />
          <input
            type="date"
            title={t('center.filterTo', 'Fins a')}
            value={filters.date_to ?? ''}
            onChange={e => { setFilters(prev => ({ ...prev, date_to: e.target.value || undefined })); setPage(0) }}
            className="h-8 text-sm border border-input rounded-md px-2 bg-background"
          />

          <div className="relative flex-1 min-w-50">
            <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground pointer-events-none" />
            <Input
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder={t('center.searchPlaceholder', 'Cercar per títol, ID o signant...')}
              className="pl-8 h-8 text-sm"
            />
          </div>
        </div>
      </div>

      {/* Table */}
      <div className="rounded-xl border overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-muted/50 border-b">
            <tr>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('center.col.status',    'Estat')}</th>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">{t('center.col.document',  'Document')}</th>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('center.col.source',    'Origen')}</th>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('center.col.signers',   'Signants')}</th>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('center.col.created',   'Creat')}</th>
              <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden lg:table-cell">{t('center.col.lastEvent', 'Darrer event')}</th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">{t('center.loading', 'Carregant...')}</td></tr>
            ) : filteredRows.length === 0 ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">{t('center.empty', 'Cap sol·licitud de signatura trobada.')}</td></tr>
            ) : filteredRows.map(row => (
              <tr
                key={row.id}
                onClick={() => navigate(`/documents/signing/${row.id}`)}
                className="border-b last:border-0 hover:bg-accent/30 cursor-pointer transition-colors"
              >
                <td className="px-4 py-3">
                  <div className="flex flex-col gap-1 items-start">
                    <StatusBadge status={row.status as SigningStatus} label={t(`center.status.${row.status}`, row.status ?? '')} />
                    {getSigningProvider(row) === 'native' && (
                      <span className="text-[10px] font-medium text-violet-700 bg-violet-50 px-1.5 py-0.5 rounded">
                        {t('center.providerNative', 'Firma pròpia')}
                      </span>
                    )}
                  </div>
                </td>
                <td className="px-4 py-3 hidden md:table-cell">
                  {(() => {
                    const hub = row.id ? commercialHub[row.id] : undefined
                    const title = hub
                      ? commercialSigningHubTitle(hub, commercialSourceLabel(hub.docType))
                      : row.document_title
                    const href = hub
                      ? commercialQuoteViewHref(hub.commercialDocumentId)
                      : (row.source_document_id ? `/documents/${row.source_document_id}` : null)
                    if (href && title) {
                      return (
                        <Link
                          to={href}
                          onClick={e => e.stopPropagation()}
                          className="text-xs text-indigo-600 hover:underline truncate block max-w-40"
                        >
                          {title}
                        </Link>
                      )
                    }
                    return <span className="text-muted-foreground text-xs">—</span>
                  })()}
                </td>
                <td className="px-4 py-3 text-muted-foreground">
                  {(() => {
                    const hub = row.id ? commercialHub[row.id] : undefined
                    if (hub) return commercialSourceLabel(hub.docType)
                    return row.source_type === 'document_existing'
                      ? t('center.sourceDocument', 'Document existent')
                      : t('center.sourceTemplate', 'Plantilla')
                  })()}
                </td>
                <td className="px-4 py-3">{signersSummary(row.signers)}</td>
                <td className="px-4 py-3 text-muted-foreground tabular-nums">{formatDate(row.created_at)}</td>
                <td className="px-4 py-3 text-muted-foreground tabular-nums hidden lg:table-cell">{formatDate(row.last_event_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-muted-foreground">
          <span>{t('center.pageInfo', 'Pàgina {{cur}} de {{total}}', { cur: page + 1, total: totalPages })}</span>
          <div className="flex gap-1">
            <Button variant="outline" size="icon" className="h-7 w-7" disabled={page === 0} onClick={() => setPage(p => p - 1)}>
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <Button variant="outline" size="icon" className="h-7 w-7" disabled={page >= totalPages - 1} onClick={() => setPage(p => p + 1)}>
              <ChevronRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      )}

      </div>
    </div>
  )
}
