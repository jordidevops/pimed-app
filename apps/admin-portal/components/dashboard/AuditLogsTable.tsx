'use client'

import { useState, useTransition, useEffect, useCallback, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useRouter, useSearchParams } from 'next/navigation'
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  createColumnHelper,
  type VisibilityState,
  type SortingState,
} from '@tanstack/react-table'
import {
  type AuditLogRow,
  type GetAuditLogsParams,
  type AuditLogsResult,
  type AuditLogsStats,
  type TenantOptionForAudit,
  getAuditLogs,
  getAuditStats,
  exportAuditLogsCsv,
} from '@/app/admin/actions/audit-logs'
import { AuditLogDetailModal } from './AuditLogDetailModal'
import { AuditStatsPanel } from './AuditStatsPanel'

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PAGE_SIZE_OPTIONS = [25, 50, 100]
const DEFAULT_PAGE_SIZE = 50

const AUTO_REFRESH_OPTIONS = [
  { label: 'Desactivat', value: 0 },
  { label: 'Cada 30s',   value: 30 },
  { label: 'Cada 60s',   value: 60 },
  { label: 'Cada 5min',  value: 300 },
]

// ---------------------------------------------------------------------------
// Action badge helpers (shared with modal)
// ---------------------------------------------------------------------------

type BadgeVariant =
  | 'red' | 'green' | 'blue' | 'indigo' | 'purple' | 'orange' | 'yellow' | 'gray'

const ACTION_VARIANT: Record<string, BadgeVariant> = {
  TENANT_DEACTIVATED:        'red',
  TENANT_ACTIVATED:          'green',
  TENANT_PLAN_CHANGED:       'blue',
  TENANT_STORAGE_BLOCKED:    'orange',
  TENANT_STORAGE_UNBLOCKED:  'green',
  SITE_CREATED:              'green',
  SITE_ACTIVATED:            'green',
  SITE_DEACTIVATED:          'red',
  SITE_RENAMED:               'blue',
  MEMBER_INVITED:             'indigo',
  MEMBER_INVITE_EMAIL_SENT:   'indigo',
  MEMBER_ROLE_CHANGED:        'purple',
  MEMBER_ACTIVATED:           'green',
  MEMBER_DEACTIVATED:         'red',
  MEMBER_REMOVED:             'red',
  EMAIL_BODY_VIEWED:          'yellow',
  FILE_DELETED:               'red',
  FILE_UPLOADED:              'green',
}

const CRITICAL_ACTIONS = new Set([
  'TENANT_DEACTIVATED', 'TENANT_PLAN_CHANGED', 'TENANT_STORAGE_BLOCKED',
  'MEMBER_ROLE_CHANGED', 'MEMBER_REMOVED', 'SITE_DEACTIVATED', 'FILE_DELETED',
])

const BADGE_CLASSES: Record<BadgeVariant, string> = {
  red:    'bg-red-50 text-red-700 ring-1 ring-red-200',
  green:  'bg-emerald-50 text-emerald-700 ring-1 ring-emerald-200',
  blue:   'bg-blue-50 text-blue-700 ring-1 ring-blue-200',
  indigo: 'bg-indigo-50 text-indigo-700 ring-1 ring-indigo-200',
  purple: 'bg-purple-50 text-purple-700 ring-1 ring-purple-200',
  orange: 'bg-orange-50 text-orange-700 ring-1 ring-orange-200',
  yellow: 'bg-yellow-50 text-yellow-700 ring-1 ring-yellow-200',
  gray:   'bg-gray-100 text-gray-600 ring-1 ring-gray-200',
}

function ActionBadge({ action }: { action: string }) {
  const variant = ACTION_VARIANT[action] ?? 'gray'
  const isCritical = CRITICAL_ACTIONS.has(action)
  return (
    <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium font-mono ${BADGE_CLASSES[variant]}`}>
      {isCritical && <span className="text-red-500" title="Acció crítica">⚠</span>}
      {action}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function truncateUuid(id: string | null | undefined): string {
  if (!id) return '—'
  return id.length > 12 ? id.slice(0, 8) + '…' : id
}

function today(): string {
  return new Date().toISOString().slice(0, 10)
}

function nDaysAgo(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return d.toISOString().slice(0, 10)
}

function downloadCsv(content: string, filename: string) {
  const blob = new Blob([content], { type: 'text/csv;charset=utf-8;' })
  const url  = URL.createObjectURL(blob)
  const a    = document.createElement('a')
  a.href     = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

// ---------------------------------------------------------------------------
// Column helper
// ---------------------------------------------------------------------------

const col = createColumnHelper<AuditLogRow>()

// ---------------------------------------------------------------------------
// Filter state type
// ---------------------------------------------------------------------------

interface Filters {
  dateFrom:   string
  dateTo:     string
  tenantId:   string
  action:     string
  entityType: string
  search:     string
}

function filtersToParams(f: Filters): Omit<GetAuditLogsParams, 'page' | 'pageSize' | 'sortColumn' | 'sortAsc'> {
  return {
    dateFrom:   f.dateFrom   || undefined,
    dateTo:     f.dateTo     || undefined,
    tenantId:   f.tenantId   || undefined,
    action:     f.action     || undefined,
    entityType: f.entityType || undefined,
    search:     f.search     || undefined,
  }
}

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface Props {
  initialData:    AuditLogsResult
  initialStats:   AuditLogsStats
  tenants:        TenantOptionForAudit[]
  initialParams:  GetAuditLogsParams
  initialFilters: Filters
}

// ---------------------------------------------------------------------------
// AuditLogsTable
// ---------------------------------------------------------------------------

export function AuditLogsTable({
  initialData,
  initialStats,
  tenants,
  initialParams,
  initialFilters,
}: Props) {
  const { t } = useTranslation('activity')
  const router = useRouter()
  const searchParams = useSearchParams()

  // ---- Data state ----
  const [data,  setData]  = useState<AuditLogsResult>(initialData)
  const [stats, setStats] = useState<AuditLogsStats>(initialStats)

  // ---- Filter state ----
  const [filters, setFilters] = useState<Filters>(initialFilters)

  // ---- Pagination & sort ----
  const [page,     setPage]     = useState(initialParams.page ?? 1)
  const [pageSize, setPageSize] = useState(initialParams.pageSize ?? DEFAULT_PAGE_SIZE)
  const [sorting,  setSorting]  = useState<SortingState>(
    initialParams.sortColumn
      ? [{ id: initialParams.sortColumn, desc: !initialParams.sortAsc }]
      : [{ id: 'created_at', desc: true }],
  )

  // ---- UI state ----
  const [isPending,  startTransition]  = useTransition()
  const [isExporting, setIsExporting]  = useState(false)
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null)
  const [showStats,  setShowStats]     = useState(true)
  const [showColMenu, setShowColMenu]  = useState(false)
  const [autoRefreshSecs, setAutoRefreshSecs] = useState(0)
  const colMenuRef = useRef<HTMLDivElement>(null)

  // ---- Column visibility ----
  const [columnVisibility, setColumnVisibility] = useState<VisibilityState>({
    site_name:  false,
    ip_address: false,
    entity_id:  true,
  })

  // ---- Columns ----
  const columns = [
    col.accessor('created_at', {
      header: t('activity.table.col_date', 'Data'),
      enableSorting: true,
      cell: (info) => (
        <span className="text-xs text-gray-500 whitespace-nowrap">{formatDate(info.getValue())}</span>
      ),
    }),
    col.accessor('action', {
      header: t('activity.table.col_action', 'Acció'),
      enableSorting: true,
      cell: (info) => <ActionBadge action={info.getValue()} />,
    }),
    col.accessor('entity_type', {
      header: t('activity.table.col_entity_type', 'Tipus entitat'),
      enableSorting: true,
      cell: (info) => (
        <span className="text-xs font-mono text-gray-600">
          {info.getValue() ?? <span className="text-gray-300">—</span>}
        </span>
      ),
    }),
    col.accessor('entity_id', {
      header: t('activity.table.col_entity_id', 'ID entitat'),
      enableSorting: false,
      cell: (info) => (
        <span
          className="text-xs font-mono text-gray-500"
          title={info.getValue() ?? undefined}
        >
          {truncateUuid(info.getValue())}
        </span>
      ),
    }),
    col.accessor('tenant_name', {
      header: t('activity.table.col_tenant', 'Tenant'),
      enableSorting: true,
      cell: (info) => (
        <span className="text-xs text-gray-700">
          {info.getValue() ?? <span className="text-gray-300 italic">—</span>}
        </span>
      ),
    }),
    col.accessor('user_email', {
      header: t('activity.table.col_actor', 'Actor'),
      enableSorting: false,
      cell: (info) => {
        const row = info.row.original
        const actor = row.user_name ?? row.user_email
        return actor ? (
          <span className="text-xs text-gray-700">{actor}</span>
        ) : (
          <span className="text-xs italic text-gray-400">
            {t('activity.modal.system', 'Sistema')}
          </span>
        )
      },
    }),
    col.accessor('site_name', {
      header: t('activity.table.col_site', 'Site'),
      enableSorting: false,
      cell: (info) => (
        <span className="text-xs text-gray-500">
          {info.getValue() ?? <span className="text-gray-300">—</span>}
        </span>
      ),
    }),
    col.accessor('ip_address', {
      header: t('activity.table.col_ip', 'IP'),
      enableSorting: false,
      cell: (info) => (
        <span className="text-xs font-mono text-gray-400">
          {info.getValue() ?? '—'}
        </span>
      ),
    }),
  ]

  const table = useReactTable({
    data: data.rows,
    columns,
    state: { columnVisibility, sorting },
    onColumnVisibilityChange: setColumnVisibility,
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    manualPagination: true,
    manualSorting: true,
  })

  // ---- Build query params from current state ----
  const buildParams = useCallback(
    (overrides?: Partial<GetAuditLogsParams>): GetAuditLogsParams => ({
      ...filtersToParams(filters),
      page,
      pageSize,
      sortColumn: sorting[0]?.id ?? 'created_at',
      sortAsc:    !(sorting[0]?.desc ?? true),
      ...overrides,
    }),
    [filters, page, pageSize, sorting],
  )

  // ---- Fetch data ----
  const fetchData = useCallback(
    (params: GetAuditLogsParams) => {
      startTransition(async () => {
        const [rows, statsData] = await Promise.all([
          getAuditLogs(params),
          getAuditStats({
            dateFrom:  params.dateFrom,
            dateTo:    params.dateTo,
            tenantId:  params.tenantId,
          }),
        ])
        setData(rows)
        setStats(statsData)
      })
    },
    [],
  )

  // ---- Sync URL search params ----
  const syncUrl = useCallback(
    (f: Filters, p: number) => {
      const params = new URLSearchParams(searchParams?.toString() ?? '')
      const entries: [string, string][] = [
        ['dateFrom',   f.dateFrom],
        ['dateTo',     f.dateTo],
        ['tenantId',   f.tenantId],
        ['action',     f.action],
        ['entityType', f.entityType],
        ['search',     f.search],
        ['page',       String(p)],
      ]
      for (const [k, v] of entries) {
        if (v) params.set(k, v)
        else   params.delete(k)
      }
      router.replace(`?${params.toString()}`, { scroll: false })
    },
    [router, searchParams],
  )

  // ---- Apply filters ----
  const applyFilters = useCallback(
    (newFilters: Filters, newPage = 1) => {
      setFilters(newFilters)
      setPage(newPage)
      syncUrl(newFilters, newPage)
      fetchData({
        ...filtersToParams(newFilters),
        page: newPage,
        pageSize,
        sortColumn: sorting[0]?.id ?? 'created_at',
        sortAsc:    !(sorting[0]?.desc ?? true),
      })
    },
    [fetchData, pageSize, sorting, syncUrl],
  )

  // ---- Sorting change: reset to page 1 ----
  useEffect(() => {
    fetchData(buildParams({ page: 1 }))
    setPage(1)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sorting])

  // ---- Page change ----
  function goToPage(newPage: number) {
    setPage(newPage)
    syncUrl(filters, newPage)
    fetchData(buildParams({ page: newPage }))
  }

  // ---- Page size change ----
  function handlePageSizeChange(newSize: number) {
    setPageSize(newSize)
    setPage(1)
    fetchData({ ...buildParams(), pageSize: newSize, page: 1 })
  }

  // ---- Auto-refresh ----
  useEffect(() => {
    if (autoRefreshSecs === 0) return
    const id = setInterval(() => {
      fetchData(buildParams())
    }, autoRefreshSecs * 1000)
    return () => clearInterval(id)
  }, [autoRefreshSecs, buildParams, fetchData])

  // ---- Close column menu on outside click ----
  useEffect(() => {
    function handler(e: MouseEvent) {
      if (colMenuRef.current && !colMenuRef.current.contains(e.target as Node)) {
        setShowColMenu(false)
      }
    }
    if (showColMenu) document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [showColMenu])

  // ---- Export CSV ----
  async function handleExport() {
    setIsExporting(true)
    try {
      const csv = await exportAuditLogsCsv(filtersToParams(filters))
      const ts  = new Date().toISOString().slice(0, 10)
      downloadCsv(csv, `audit-logs-${ts}.csv`)
    } finally {
      setIsExporting(false)
    }
  }

  // ---- Clear filters ----
  function clearFilters() {
    const fresh: Filters = {
      dateFrom:   nDaysAgo(7),
      dateTo:     today(),
      tenantId:   '',
      action:     '',
      entityType: '',
      search:     '',
    }
    applyFilters(fresh)
  }

  const totalPages = Math.max(1, Math.ceil(data.total / pageSize))
  const fromRow    = data.total === 0 ? 0 : (page - 1) * pageSize + 1
  const toRow      = Math.min(page * pageSize, data.total)

  // ---- Render ----
  return (
    <div className="space-y-6">
      {/* ---- Stats panel (collapsible) ---- */}
      <div>
        <button
          onClick={() => setShowStats((s) => !s)}
          className="flex items-center gap-1.5 text-sm font-medium text-gray-600 hover:text-gray-900 transition mb-3"
        >
          <svg
            className={`w-4 h-4 transition-transform ${showStats ? 'rotate-90' : ''}`}
            fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true"
          >
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" />
          </svg>
          {t('activity.stats.title', 'Estadístiques')}
        </button>
        {showStats && <AuditStatsPanel stats={stats} />}
      </div>

      {/* ---- Filters ---- */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm p-4 space-y-3">
        {/* Row 1: dates + tenant */}
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex flex-col gap-1 text-xs font-medium text-gray-600">
            {t('activity.filters.date_from', 'Des de')}
            <input
              type="date"
              value={filters.dateFrom}
              onChange={(e) => setFilters((f) => ({ ...f, dateFrom: e.target.value }))}
              className="border border-gray-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-gray-600">
            {t('activity.filters.date_to', 'Fins a')}
            <input
              type="date"
              value={filters.dateTo}
              onChange={(e) => setFilters((f) => ({ ...f, dateTo: e.target.value }))}
              className="border border-gray-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-gray-600">
            {t('activity.filters.tenant', 'Tenant')}
            <select
              value={filters.tenantId}
              onChange={(e) => setFilters((f) => ({ ...f, tenantId: e.target.value }))}
              className="border border-gray-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 min-w-45"
            >
              <option value="">{t('activity.filters.tenant_all', 'Tots els tenants')}</option>
              {tenants.map((tn) => (
                <option key={tn.id} value={tn.id}>{tn.name}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-gray-600">
            {t('activity.filters.action', 'Acció')}
            <input
              type="text"
              value={filters.action}
              onChange={(e) => setFilters((f) => ({ ...f, action: e.target.value }))}
              placeholder={t('activity.filters.action_placeholder', 'Filtra per acció...')}
              className="border border-gray-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 w-40"
            />
          </label>
          <label className="flex flex-col gap-1 text-xs font-medium text-gray-600">
            {t('activity.filters.entity_type', 'Tipus entitat')}
            <input
              type="text"
              value={filters.entityType}
              onChange={(e) => setFilters((f) => ({ ...f, entityType: e.target.value }))}
              placeholder={t('activity.filters.entity_type_placeholder', 'Filtra per tipus...')}
              className="border border-gray-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 w-36"
            />
          </label>
        </div>

        {/* Row 2: search + buttons */}
        <div className="flex flex-wrap items-center gap-2">
          <input
            type="search"
            value={filters.search}
            onChange={(e) => setFilters((f) => ({ ...f, search: e.target.value }))}
            onKeyDown={(e) => {
              if (e.key === 'Enter') applyFilters(filters)
            }}
            placeholder={t(
              'activity.filters.search_placeholder',
              'Cerca per acció, entitat, usuari, payload...',
            )}
            className="border border-gray-300 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 flex-1 min-w-55"
          />
          <button
            onClick={() => applyFilters(filters)}
            disabled={isPending}
            className="px-3 py-1.5 rounded-lg bg-indigo-600 text-white text-sm font-medium hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {isPending ? '…' : t('activity.filters.refresh', 'Actualitzar')}
          </button>
          <button
            onClick={clearFilters}
            className="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-600 text-sm font-medium hover:bg-gray-50 transition"
          >
            {t('activity.filters.clear', 'Netejar filtres')}
          </button>
          <button
            onClick={handleExport}
            disabled={isExporting || isPending}
            className="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-600 text-sm font-medium hover:bg-gray-50 transition disabled:opacity-50"
          >
            {isExporting
              ? t('activity.filters.exporting', 'Exportant...')
              : t('activity.filters.export_csv', 'Exportar CSV')}
          </button>

          {/* Auto-refresh */}
          <select
            value={autoRefreshSecs}
            onChange={(e) => setAutoRefreshSecs(Number(e.target.value))}
            className="border border-gray-300 rounded-lg px-2 py-1.5 text-xs text-gray-600 focus:outline-none focus:ring-2 focus:ring-indigo-500"
            aria-label={t('activity.filters.auto_refresh', 'Auto-refresh')}
          >
            {AUTO_REFRESH_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.value === 0
                  ? t('activity.filters.auto_refresh_off', 'Auto-refresh: off')
                  : opt.label}
              </option>
            ))}
          </select>

          {/* Column visibility */}
          <div className="relative" ref={colMenuRef}>
            <button
              onClick={() => setShowColMenu((v) => !v)}
              className="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-600 text-sm font-medium hover:bg-gray-50 transition"
            >
              {t('activity.filters.columns', 'Columnes')}
            </button>
            {showColMenu && (
              <div className="absolute right-0 top-full mt-1 z-20 bg-white border border-gray-200 rounded-xl shadow-lg p-3 min-w-45 space-y-1">
                {table.getAllLeafColumns().map((col) => (
                  <label key={col.id} className="flex items-center gap-2 text-sm text-gray-700 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={col.getIsVisible()}
                      onChange={col.getToggleVisibilityHandler()}
                      className="rounded"
                    />
                    {typeof col.columnDef.header === 'string'
                      ? col.columnDef.header
                      : col.id}
                  </label>
                ))}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ---- Table ---- */}
      <div className="bg-white rounded-2xl border border-gray-100 shadow-sm overflow-hidden">
        {/* Table header row with total count */}
        <div className="px-5 py-3 border-b border-gray-100 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-gray-700">
            {t('activity.table.title', 'Registres d\'auditoria')}
          </h2>
          <span className="text-xs text-gray-400">
            {t('activity.table.total_rows', '{{total}} registres', { total: data.total })}
          </span>
        </div>

        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              {table.getHeaderGroups().map((hg) => (
                <tr key={hg.id} className="bg-gray-50 border-b border-gray-100 text-left">
                  {hg.headers.map((header) => (
                    <th
                      key={header.id}
                      className={`px-4 py-3 text-xs font-semibold text-gray-500 uppercase tracking-wide whitespace-nowrap ${
                        header.column.getCanSort() ? 'cursor-pointer select-none hover:text-gray-700' : ''
                      }`}
                      onClick={header.column.getToggleSortingHandler()}
                    >
                      <span className="flex items-center gap-1">
                        {flexRender(header.column.columnDef.header, header.getContext())}
                        {header.column.getCanSort() && (
                          <span className="text-gray-300">
                            {header.column.getIsSorted() === 'asc'
                              ? '↑'
                              : header.column.getIsSorted() === 'desc'
                              ? '↓'
                              : '↕'}
                          </span>
                        )}
                      </span>
                    </th>
                  ))}
                </tr>
              ))}
            </thead>

            <tbody className="divide-y divide-gray-50">
              {isPending && data.rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={table.getVisibleLeafColumns().length}
                    className="px-4 py-12 text-center text-sm text-gray-400"
                  >
                    {t('activity.table.loading', 'Carregant registres...')}
                  </td>
                </tr>
              ) : data.rows.length === 0 ? (
                <tr>
                  <td
                    colSpan={table.getVisibleLeafColumns().length}
                    className="px-4 py-12 text-center text-sm text-gray-400"
                  >
                    {t('activity.table.empty', 'No hi ha registres per als filtres actuals.')}
                  </td>
                </tr>
              ) : (
                table.getRowModel().rows.map((row) => (
                  <tr
                    key={row.id}
                    className={`hover:bg-indigo-50/40 cursor-pointer transition-colors ${
                      isPending ? 'opacity-50' : ''
                    }`}
                    onClick={() => setSelectedLogId(row.original.id)}
                    role="button"
                    tabIndex={0}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault()
                        setSelectedLogId(row.original.id)
                      }
                    }}
                    aria-label={`Veure detall del log ${row.original.action} del ${formatDate(row.original.created_at)}`}
                  >
                    {row.getVisibleCells().map((cell) => (
                      <td key={cell.id} className="px-4 py-3 align-top">
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>

        {/* ---- Pagination ---- */}
        {data.total > 0 && (
          <div className="px-5 py-3 border-t border-gray-100 flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-2 text-xs text-gray-500">
              {t('activity.pagination.showing', 'Mostrant {{from}}–{{to}} de {{total}}', {
                from:  fromRow,
                to:    toRow,
                total: data.total,
              })}
              <span className="mx-1 text-gray-300">|</span>
              <label className="flex items-center gap-1">
                {t('activity.pagination.page_size', 'Files per pàgina')}
                <select
                  value={pageSize}
                  onChange={(e) => handlePageSizeChange(Number(e.target.value))}
                  className="ml-1 border border-gray-200 rounded px-1.5 py-0.5 text-xs"
                >
                  {PAGE_SIZE_OPTIONS.map((s) => (
                    <option key={s} value={s}>{s}</option>
                  ))}
                </select>
              </label>
            </div>

            <div className="flex items-center gap-1">
              <button
                onClick={() => goToPage(1)}
                disabled={page === 1 || isPending}
                className="px-2 py-1 text-xs rounded border border-gray-200 disabled:opacity-40 hover:bg-gray-50 transition"
              >
                «
              </button>
              <button
                onClick={() => goToPage(page - 1)}
                disabled={page === 1 || isPending}
                className="px-3 py-1 text-xs rounded border border-gray-200 disabled:opacity-40 hover:bg-gray-50 transition"
              >
                {t('activity.pagination.prev', 'Anterior')}
              </button>
              <span className="px-3 py-1 text-xs text-gray-600 font-medium">
                {t('activity.table.page_info', 'Pàgina {{page}} de {{total}}', {
                  page,
                  total: totalPages,
                })}
              </span>
              <button
                onClick={() => goToPage(page + 1)}
                disabled={page >= totalPages || isPending}
                className="px-3 py-1 text-xs rounded border border-gray-200 disabled:opacity-40 hover:bg-gray-50 transition"
              >
                {t('activity.pagination.next', 'Següent')}
              </button>
              <button
                onClick={() => goToPage(totalPages)}
                disabled={page >= totalPages || isPending}
                className="px-2 py-1 text-xs rounded border border-gray-200 disabled:opacity-40 hover:bg-gray-50 transition"
              >
                »
              </button>
            </div>
          </div>
        )}
      </div>

      {/* ---- Detail modal ---- */}
      <AuditLogDetailModal
        logId={selectedLogId}
        onClose={() => setSelectedLogId(null)}
      />
    </div>
  )
}
