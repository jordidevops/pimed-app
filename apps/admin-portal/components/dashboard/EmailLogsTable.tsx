'use client'

import { useState, useTransition, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  createColumnHelper,
} from '@tanstack/react-table'
import {
  type EmailLogDetail,
  type EmailLogRow,
  type GetEmailLogsParams,
  type EmailLogsResult,
  type TenantOption,
  type SiteOption,
  type EmailMetrics,
  getEmailLogs,
  getSiteOptions,
  exportEmailLogsCsv,
} from '@/app/admin/actions/email-logs'
import { EmailLogDetailModal } from './EmailLogDetailModal'
import { EmailStatsGrid } from './EmailStatsGrid'

// ---------------------------------------------------------------------------
// Status badge
// ---------------------------------------------------------------------------

const STATUS_KEYS = ['queued', 'processing', 'sent', 'delivered', 'bounced', 'failed', 'complained', 'suppressed'] as const
const STATUS_CLASSES: Record<string, string> = {
  queued: 'bg-gray-100 text-gray-700',
  processing: 'bg-blue-100 text-blue-700',
  sent: 'bg-green-100 text-green-700',
  delivered: 'bg-emerald-600 text-white',
  bounced: 'bg-orange-100 text-orange-700',
  failed: 'bg-red-100 text-red-700',
  complained: 'bg-purple-100 text-purple-700',
  suppressed: 'bg-gray-700 text-white',
}
const STATUS_LABELS: Record<string, string> = {
  queued: 'En cua',
  processing: 'Processant',
  sent: 'Enviat',
  delivered: 'Entregat',
  bounced: 'Rebutjat',
  failed: 'Error',
  complained: 'Queixa d\'spam',
  suppressed: 'Suprimit',
}
const STATUS_ICONS: Record<string, string> = {
  delivered: '✓',
}

function StatusBadge({ status }: { status: string }) {
  const { t } = useTranslation('email_logs')
  const label = t(`email_logs.status.${status}` as string, status)
  const className = STATUS_CLASSES[status] ?? 'bg-gray-100 text-gray-600'
  const icon = STATUS_ICONS[status]
  return (
    <span
      className={`inline-flex items-center gap-0.5 rounded-full px-2 py-0.5 text-xs font-medium ${className}`}
    >
      {icon && <span aria-hidden="true">{icon}</span>}
      {label}
    </span>
  )
}

function getManualSyncAt(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return null
  }

  const resendSync = (metadata as { resend_sync?: unknown }).resend_sync
  if (!resendSync || typeof resendSync !== 'object' || Array.isArray(resendSync)) {
    return null
  }

  const syncedAt = (resendSync as { synced_at?: unknown }).synced_at
  return typeof syncedAt === 'string' && syncedAt ? syncedAt : null
}

function getWebhookSyncAt(metadata: unknown): string | null {
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) {
    return null
  }
  const receivedAt = (metadata as { received_at?: unknown }).received_at
  return typeof receivedAt === 'string' && receivedAt ? receivedAt : null
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  return d.toLocaleString('ca-ES', {
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function sevenDaysAgo(): string {
  const d = new Date()
  d.setDate(d.getDate() - 7)
  return d.toISOString().slice(0, 10)
}

function formatDuration(ms: number | null): string {
  if (ms == null || ms < 0) return '—'
  if (ms < 1000) return `${Math.round(ms)} ms`
  const totalSecs = Math.round(ms / 1000)
  if (totalSecs < 60) return `${totalSecs}s`
  const h = Math.floor(totalSecs / 3600)
  const m = Math.floor((totalSecs % 3600) / 60)
  const s = totalSecs % 60
  if (h > 0) return `${h}h ${m}m ${s}s`
  return `${m}m ${s}s`
}

// ---------------------------------------------------------------------------
// Column helper
// ---------------------------------------------------------------------------

const col = createColumnHelper<EmailLogRow>()

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface EmailLogsTableProps {
  initialData: EmailLogsResult
  tenants: TenantOption[]
  initialParams: GetEmailLogsParams
  initialMetrics: EmailMetrics
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function EmailLogsTable({
  initialData,
  tenants,
  initialParams,
  initialMetrics,
}: EmailLogsTableProps) {
  const { t } = useTranslation('email_logs')
  const [data, setData] = useState<EmailLogsResult>(initialData)
  const [isPending, startTransition] = useTransition()
  const [isExporting, startExportTransition] = useTransition()
  const [committedParams, setCommittedParams] = useState<GetEmailLogsParams>(initialParams)

  // Filter state
  const [dateFrom, setDateFrom] = useState(
    initialParams.dateFrom ?? sevenDaysAgo(),
  )
  const [dateTo, setDateTo] = useState(initialParams.dateTo ?? today())
  const [tenantId, setTenantId] = useState(initialParams.tenantId ?? '')
  const [siteId, setSiteId] = useState(initialParams.siteId ?? '')
  const [sites, setSites] = useState<SiteOption[]>([])
  const [status, setStatus] = useState(initialParams.status ?? '')
  const [searchInput, setSearchInput] = useState(initialParams.search ?? '')
  const [page, setPage] = useState(initialParams.page ?? 1)
  const [sortColumn, setSortColumn] = useState(initialParams.sortColumn ?? 'created_at')
  const [sortAsc, setSortAsc] = useState(initialParams.sortAsc ?? false)

  // Load sites when tenant changes
  useEffect(() => {
    if (!tenantId) {
      setSites([])
      setSiteId('')
      return
    }
    getSiteOptions(tenantId).then(setSites).catch(() => setSites([]))
  }, [tenantId])

  // Modal state
  const [modalLogId, setModalLogId] = useState<string | null>(null)

  // ---------------------------------------------------------------------------
  // Fetch helpers
  // ---------------------------------------------------------------------------

  function buildParams(overrides: Partial<GetEmailLogsParams> = {}): GetEmailLogsParams {
    return {
      dateFrom,
      dateTo,
      tenantId: tenantId || undefined,
      siteId: siteId || undefined,
      status: status || undefined,
      search: searchInput || undefined,
      page,
      pageSize: data.pageSize,
      sortColumn,
      sortAsc,
      ...overrides,
    }
  }

  function fetchPage(newPage: number) {
    setPage(newPage)
    startTransition(async () => {
      const result = await getEmailLogs(buildParams({ page: newPage }))
      setData(result)
    })
  }

  function applyFilters() {
    const newParams = buildParams({ page: 1 })
    setPage(1)
    setCommittedParams(newParams)
    startTransition(async () => {
      const result = await getEmailLogs(newParams)
      setData(result)
    })
  }

  function handleSearchKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter') applyFilters()
  }

  function handleSort(column: string) {
    const newAsc = sortColumn === column ? !sortAsc : false
    setSortColumn(column)
    setSortAsc(newAsc)
    const newParams = buildParams({ page: 1, sortColumn: column, sortAsc: newAsc })
    setPage(1)
    setCommittedParams(newParams)
    startTransition(async () => {
      const result = await getEmailLogs(newParams)
      setData(result)
    })
  }

  function clearSearch() {
    setSearchInput('')
    const newParams = buildParams({ page: 1, search: '' })
    setPage(1)
    setCommittedParams(newParams)
    startTransition(async () => {
      const result = await getEmailLogs(newParams)
      setData(result)
    })
  }

  function handleModalLogUpdated(updatedLog: EmailLogDetail) {
    setData((prev) => ({
      ...prev,
      rows: prev.rows.map((row) => {
        if (row.id !== updatedLog.id) return row

        return {
          ...row,
          status: updatedLog.status,
          delivered_at: updatedLog.delivered_at,
          metadata: updatedLog.metadata,
          last_error: updatedLog.last_error,
          error_history: updatedLog.error_history,
          attempt_count: updatedLog.attempt_count,
          is_dead_letter: updatedLog.is_dead_letter,
        }
      }),
    }))
  }

  // ---------------------------------------------------------------------------
  // CSV export
  // ---------------------------------------------------------------------------

  function handleExport() {
    startExportTransition(async () => {
      const csv = await exportEmailLogsCsv(committedParams)
      const blob = new Blob(['\uFEFF' + csv], {
        type: 'text/csv;charset=utf-8;',
      })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `email-logs-${committedParams.dateFrom ?? 'all'}-${committedParams.dateTo ?? 'all'}.csv`
      a.click()
      URL.revokeObjectURL(url)
    })
  }

  // ---------------------------------------------------------------------------
  // Sort helper
  // ---------------------------------------------------------------------------

  function SortBtn({ colKey, label }: { colKey: string; label: string }) {
    const isActive = sortColumn === colKey
    return (
      <button
        type="button"
        onClick={() => handleSort(colKey)}
        className="inline-flex items-center gap-0.5 group hover:text-gray-700 font-semibold uppercase tracking-wide"
      >
        {label}
        <span className="text-[9px] ml-0.5 text-gray-300 group-hover:text-gray-400">
          {isActive ? (sortAsc ? '▲' : '▼') : '↕'}
        </span>
      </button>
    )
  }

  // ---------------------------------------------------------------------------
  // TanStack Table columns
  // ---------------------------------------------------------------------------

  const columns = [
    col.accessor('created_at', {
      header: () => <SortBtn colKey="created_at" label={t('email_logs.table.col_date', 'Data')} />,
      cell: (info) => (
        <span className="whitespace-nowrap text-xs text-gray-600">
          {formatDate(info.getValue())}
        </span>
      ),
    }),
    col.accessor('tenant_name', {
      header: t('email_logs.table.col_tenant', 'Tenant'),
      cell: (info) => (
        <span className="text-sm font-medium text-gray-800 truncate max-w-30 block">
          {info.getValue() ?? '—'}
        </span>
      ),
    }),    col.accessor('site_name', {
      header: t('email_logs.table.col_site', 'Site'),
      cell: (info) => (
        <span className="hidden md:block text-xs text-gray-500 truncate max-w-28">
          {info.getValue() ?? '\u2014'}
        </span>
      ),
    }),    col.accessor('from_email', {
      header: () => <SortBtn colKey="from_email" label={t('email_logs.table.col_from', 'De')} />,
      cell: (info) => {
        const row = info.row.original
        return (
          <span className="text-xs text-gray-700 truncate max-w-37.5 block">
            {row.from_name ? `${row.from_name} <${row.from_email}>` : row.from_email}
          </span>
        )
      },
    }),
    col.accessor('to_emails', {
      header: t('email_logs.table.col_to', 'Per a'),
      cell: (info) => {
        const emails = info.getValue()
        return (
          <span className="text-xs text-gray-700 truncate max-w-37.5 block">
            {emails[0] ?? '—'}
            {emails.length > 1 && (
              <span className="ml-1 text-gray-400">+{emails.length - 1}</span>
            )}
          </span>
        )
      },
    }),
    col.accessor('subject', {
      header: t('email_logs.table.col_subject', 'Assumpte'),
      cell: (info) => {
        const val = info.getValue()
        return (
          <span
            className="text-sm text-gray-700 truncate max-w-50 block"
            title={val ?? undefined}
          >
            {val ?? <span className="italic text-gray-400">{t('email_logs.table.no_subject', '(sense assumpte)')}</span>}
          </span>
        )
      },
    }),
    col.accessor('status', {
      header: () => <SortBtn colKey="status" label={t('email_logs.table.col_status', 'Estat')} />,
      cell: (info) => {
        const row = info.row.original
        const manualSyncAt  = getManualSyncAt(row.metadata)
        const webhookSyncAt = getWebhookSyncAt(row.metadata)

        return (
          <div className="inline-flex items-center gap-1.5">
            <StatusBadge status={info.getValue()} />
            {webhookSyncAt && (
              <span
                className="text-blue-500 text-xs"
                title={t('email_logs.table.webhook_sync_at', 'Actualitzat per Webhook: {{date}}', { date: formatDate(webhookSyncAt) })}
                aria-label={t('email_logs.table.webhook_sync_at', 'Actualitzat per Webhook: {{date}}', { date: formatDate(webhookSyncAt) })}
              >
                ⚡
              </span>
            )}
            {manualSyncAt && (
              <span
                className="text-gray-400 text-xs"
                title={t('email_logs.table.manual_sync_at', 'Sincronitzat manualment: {{date}}', { date: formatDate(manualSyncAt) })}
                aria-label={t('email_logs.table.manual_sync_at', 'Sincronitzat manualment: {{date}}', { date: formatDate(manualSyncAt) })}
              >
                🔄
              </span>
            )}
          </div>
        )
      },
    }),
    col.accessor('attempt_count', {
      header: () => <SortBtn colKey="attempt_count" label={t('email_logs.table.col_attempts', 'Intents')} />,
      cell: (info) => {
        const row = info.row.original
        return (
          <span
            className={`text-xs ${row.is_dead_letter ? 'text-red-600 font-semibold' : 'text-gray-500'}`}
          >
            {info.getValue()}/{row.max_retries}
            {row.is_dead_letter && ' 💀'}
          </span>
        )
      },
    }),
    col.accessor('processing_time_ms', {
      header: () => <SortBtn colKey="processing_time_ms" label={t('email_logs.table.col_processing_time', 'Temps de procés')} />,
      cell: (info) => (
        <span className="text-xs text-gray-500 whitespace-nowrap">
          {formatDuration(info.getValue())}
        </span>
      ),
    }),
    col.display({
      id: 'actions',
      header: '',
      cell: (info) => (
        <button
          type="button"
          onClick={() => setModalLogId(info.row.original.id)}
          className="text-indigo-600 hover:text-indigo-800 text-xs font-medium whitespace-nowrap"
        >
          {t('email_logs.table.row_details', 'Detalls')}
        </button>
      ),
    }),
  ]

  const table = useReactTable({
    data: data.rows,
    columns,
    getCoreRowModel: getCoreRowModel(),
    manualPagination: true,
    rowCount: data.total,
  })

  // ---------------------------------------------------------------------------
  // Pagination info
  // ---------------------------------------------------------------------------

  const totalPages = Math.ceil(data.total / data.pageSize)
  const currentPage = data.page

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  return (
    <div className="space-y-4">
      {/* Visual Insights */}
      <EmailStatsGrid initialMetrics={initialMetrics} filters={committedParams} />

      {/* Filters */}
      <div className="flex flex-wrap gap-3 items-end">
        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-gray-600">Des de</label>
          <input
            type="date"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
            className="h-9 rounded-md border border-gray-300 px-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-gray-600">Fins a</label>
          <input
            type="date"
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
            className="h-9 rounded-md border border-gray-300 px-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-gray-600">
            {t('email_logs.filters.tenant', 'Tenant')}
          </label>
          <select
            value={tenantId}
            onChange={(e) => { setTenantId(e.target.value); setSiteId('') }}
            className="h-9 rounded-md border border-gray-300 px-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
          >
            <option value="">{t('email_logs.filters.all_tenants', 'Tots els tenants')}</option>
            {tenants.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </div>

        {/* Site — only shown when a tenant is selected */}
        {tenantId && (
          <div className="flex flex-col gap-1">
            <label className="text-xs font-medium text-gray-600">
              {t('email_logs.filters.site', 'Site')}
            </label>
            <select
              value={siteId}
              onChange={(e) => setSiteId(e.target.value)}
              className="h-9 rounded-md border border-gray-300 px-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
            >
              <option value="">{t('email_logs.filters.all_sites', 'Tots els sites')}</option>
              {sites.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>
        )}

        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-gray-600">Estat</label>
          <select
            value={status}
            onChange={(e) => setStatus(e.target.value)}
            className="h-9 rounded-md border border-gray-300 px-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
          >
            <option value="">Tots els estats</option>
            {STATUS_KEYS.map((key) => (
              <option key={key} value={key}>
                {STATUS_LABELS[key] ?? key}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-xs font-medium text-gray-600">Cerca</label>
          <div className="flex gap-1">
            <div className="relative">
              <input
                type="text"
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
                onKeyDown={handleSearchKeyDown}
                placeholder="Email, assumpte, message ID…"
                className="h-9 w-64 rounded-md border border-gray-300 px-2 pr-7 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
              />
              {searchInput && (
                <button
                  type="button"
                  onClick={clearSearch}
                  className="absolute right-2 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-600 text-sm leading-none"
                  aria-label={t('email_logs.filters.clear_search', 'Esborrar cerca')}
                >
                  ✕
                </button>
              )}
            </div>
            <button
              type="button"
              onClick={applyFilters}
              className="h-9 px-3 rounded-md bg-indigo-600 text-white text-sm hover:bg-indigo-700 transition-colors"
            >
              Cercar
            </button>
          </div>
        </div>

        <button
          type="button"
          onClick={handleExport}
          disabled={isExporting || data.total === 0}
          className="h-9 px-3 rounded-md border border-gray-300 text-sm text-gray-700 hover:bg-gray-50 disabled:opacity-50 flex items-center gap-1.5 self-end"
        >
          <svg
            className="w-4 h-4"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"
            />
          </svg>
          {isExporting ? 'Exportant…' : 'Exportar CSV'}
        </button>
      </div>

      {/* Summary */}
      <p className="text-sm text-gray-500">
        {isPending
          ? 'Carregant…'
          : `${data.total.toLocaleString('ca-ES')} registres trobats`}
      </p>

      {/* Table */}
      <div className="rounded-xl border border-gray-200 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 text-sm">
            <thead className="bg-gray-50">
              {table.getHeaderGroups().map((hg) => (
                <tr key={hg.id}>
                  {hg.headers.map((header) => (
                    <th
                      key={header.id}
                      className="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap"
                    >
                      {flexRender(
                        header.column.columnDef.header,
                        header.getContext(),
                      )}
                    </th>
                  ))}
                </tr>
              ))}
            </thead>
            <tbody
              className={`divide-y divide-gray-100 bg-white transition-opacity ${isPending ? 'opacity-50' : ''}`}
            >
              {table.getRowModel().rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={columns.length}
                    className="px-4 py-10 text-center text-sm text-gray-400"
                  >
                    {isPending ? 'Carregant…' : 'Cap registre per als filtres seleccionats'}
                  </td>
                </tr>
              ) : (
                table.getRowModel().rows.map((row) => (
                  <tr
                    key={row.id}
                    className="hover:bg-gray-50 cursor-pointer"
                    onClick={() => setModalLogId(row.original.id)}
                  >
                    {row.getVisibleCells().map((cell) => (
                      <td
                        key={cell.id}
                        className="px-4 py-3 whitespace-nowrap"
                        onClick={
                          cell.column.id === 'actions'
                            ? (e) => e.stopPropagation()
                            : undefined
                        }
                      >
                        {flexRender(
                          cell.column.columnDef.cell,
                          cell.getContext(),
                        )}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm text-gray-600">
          <span>
            Pàgina {currentPage} de {totalPages}
          </span>
          <div className="flex items-center gap-1">
            <button
              type="button"
              onClick={() => fetchPage(1)}
              disabled={currentPage <= 1 || isPending}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50 font-mono"
              title={t('email_logs.pagination.first_page', 'Primera pàgina')}
            >
              «
            </button>
            <button
              type="button"
              onClick={() => fetchPage(currentPage - 1)}
              disabled={currentPage <= 1 || isPending}
              className="px-3 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50"
            >
              ← Anterior
            </button>
            <button
              type="button"
              onClick={() => fetchPage(currentPage + 1)}
              disabled={currentPage >= totalPages || isPending}
              className="px-3 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50"
            >
              Següent →
            </button>
            <button
              type="button"
              onClick={() => fetchPage(totalPages)}
              disabled={currentPage >= totalPages || isPending}
              className="px-2 py-1 rounded border border-gray-300 disabled:opacity-40 hover:bg-gray-50 font-mono"
              title={t('email_logs.pagination.last_page', 'Última pàgina')}
            >
              »
            </button>
          </div>
        </div>
      )}

      {/* Detail modal */}
      {modalLogId && (
        <EmailLogDetailModal
          logId={modalLogId}
          onClose={() => setModalLogId(null)}
          onLogUpdated={handleModalLogUpdated}
        />
      )}
    </div>
  )
}
