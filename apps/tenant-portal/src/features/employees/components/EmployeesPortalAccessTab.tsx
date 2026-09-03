import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import {
  ChevronLeft,
  ChevronRight,
  History,
  LayoutGrid,
  Link2,
  List,
  Loader2,
  Mail,
  X,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { usePublicSiteForEmployee } from '@/features/public-portal/api/usePublicSiteForEmployee'
import { useEmployeePortalOverview } from '@/features/employee-portal/api/useEmployeePortalOverview'
import type {
  PortalAccessOverviewPortalFilter,
  PortalAccessOverviewQuery,
  PortalAccessOverviewRow,
  PortalAccessOverviewSort,
} from '@/features/employee-portal/api/employeePortalOverviewTypes'
import type {
  FetchPortalTokenBatchResults,
  StartPortalTokenBatchResult,
} from '@/features/employee-portal/api/employeePortalBatchTypes'
import {
  createEmployeePortalToken,
  listEmployeePortalTokens,
  sendEmployeePortalAccessEmail,
} from '@/features/employee-portal/api/employeePortalService'
import { employeePortalKeys } from '@/features/employee-portal/api/employeePortalKeys'
import type { EmployeePortalToken } from '@/features/employee-portal/api/employeePortalTypes'
import { useEmployeePortalTokens } from '@/features/employee-portal/api/useEmployeePortalTokens'
import { CreatePortalTokenDialog } from '@/features/employee-portal/components/CreatePortalTokenDialog'
import { PortalAccessHubHelp } from '@/features/employee-portal/components/PortalAccessHubHelp'
import { PortalAccessOverviewCards } from '@/features/employee-portal/components/PortalAccessOverviewCards'
import { PortalAccessOverviewTable } from '@/features/employee-portal/components/PortalAccessOverviewTable'
import { PortalTokenBatchDialog } from '@/features/employee-portal/components/PortalTokenBatchDialog'
import { useEmployees } from '../api/useEmployees'
import { FilterPillRow, type FilterPillOption } from './EmployeeFilterPills'
import { PortalTokenBatchRecoveryBanner } from '@/features/employee-portal/components/PortalTokenBatchRecoveryBanner'
import { PortalTokenBatchRecentDialog } from '@/features/employee-portal/components/PortalTokenBatchRecentDialog'
import { PortalTokenBatchResultsDialog } from '@/features/employee-portal/components/PortalTokenBatchResultsDialog'
import { PortalTokenRevealDialog } from '@/features/employee-portal/components/PortalTokenRevealDialog'
import { RevokePortalTokenDialog } from '@/features/employee-portal/components/RevokePortalTokenDialog'
import { hasEmployeeDocumentId } from '@/features/employee-portal/utils/portalDocumentId'
import { overviewRowToRevokeToken } from '@/features/employee-portal/utils/portalOverviewRowUtils'
import { buildEmployeePortalBootstrapUrl } from '@/features/employee-portal/utils/portalUrl'

const PAGE_SIZE = 50
const VIEW_STORAGE_KEY = 'employees.portalAccessView'

type OverviewView = 'cards' | 'table'

function readStoredView(): OverviewView {
  try {
    const v = localStorage.getItem(VIEW_STORAGE_KEY)
    if (v === 'cards' || v === 'table') return v
  } catch {
    /* ignore */
  }
  return 'cards'
}

function isTokenActive(token: EmployeePortalToken): boolean {
  if (token.revoked_at || !token.is_active) return false
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return false
  return true
}

function buildRegenerateTokenInput(token: EmployeePortalToken) {
  const pinRequired = token.pin_required
  return {
    label: token.label ?? undefined,
    pinRequired,
    pinMustSet: pinRequired,
    expiresAt: token.expires_at,
  }
}

interface EmployeesPortalAccessTabProps {
  onSubtitleChange?: (count: number) => void
}

export function EmployeesPortalAccessTab({ onSubtitleChange }: EmployeesPortalAccessTabProps) {
  const { t } = useTranslation('employees')
  const queryClient = useQueryClient()
  const { sites, activeTenant, selectedSiteId } = useTenant()
  const { data: departments = [] } = useDepartments()
  const { data: allEmployees = [] } = useEmployees()

  const [search, setSearch] = useState('')
  const [filterSiteId, setFilterSiteId] = useState('')
  const [filterDepartmentId, setFilterDepartmentId] = useState('')
  const [filterEmployeeStatus, setFilterEmployeeStatus] = useState('active')
  const [portalFilter, setPortalFilter] = useState<PortalAccessOverviewPortalFilter | ''>('')
  const [sort, setSort] = useState<PortalAccessOverviewSort>('name')
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc')
  const [page, setPage] = useState(0)
  const [viewMode, setViewMode] = useState<OverviewView>(readStoredView)

  const effectiveSiteId = selectedSiteId || filterSiteId || ''

  useEffect(() => {
    if (selectedSiteId) setFilterSiteId('')
    setFilterDepartmentId('')
    setPage(0)
  }, [selectedSiteId])

  useEffect(() => {
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, viewMode)
    } catch {
      /* ignore */
    }
  }, [viewMode])

  const [selectedIds, setSelectedIds] = useState<Set<string>>(() => new Set())
  const [batchDialogOpen, setBatchDialogOpen] = useState(false)
  const [batchResultsOpen, setBatchResultsOpen] = useState(false)
  const [recentBatchesOpen, setRecentBatchesOpen] = useState(false)
  const [batchStart, setBatchStart] = useState<StartPortalTokenBatchResult | null>(null)
  const [batchResults, setBatchResults] = useState<FetchPortalTokenBatchResults | null>(null)

  const [rowActionEmployee, setRowActionEmployee] = useState<PortalAccessOverviewRow | null>(null)
  const [createOpen, setCreateOpen] = useState(false)
  const [revokeToken, setRevokeToken] = useState<EmployeePortalToken | null>(null)
  const [regenerateToken, setRegenerateToken] = useState<EmployeePortalToken | null>(null)
  const [regeneratePending, setRegeneratePending] = useState(false)
  const [regenerateError, setRegenerateError] = useState<string | null>(null)
  const [regenerateSuccess, setRegenerateSuccess] = useState<string | null>(null)
  const [revealOpen, setRevealOpen] = useState(false)
  const [revealSecret, setRevealSecret] = useState('')
  const [revealTokenId, setRevealTokenId] = useState('')
  const [revealLabel, setRevealLabel] = useState('')
  const [revealSuperseded, setRevealSuperseded] = useState(false)

  const rowActionEmployeeId = rowActionEmployee?.employee_id
  const { data: rowActionTokens = [] } = useEmployeePortalTokens(rowActionEmployeeId)
  const { data: resolvedPublicSite, isLoading: resolvingPublicSite } =
    usePublicSiteForEmployee(rowActionEmployeeId)

  const bootstrapUrl = useMemo(() => {
    if (!revealSecret || !activeTenant || !resolvedPublicSite) return ''
    return buildEmployeePortalBootstrapUrl(revealSecret, resolvedPublicSite, activeTenant.slug)
  }, [revealSecret, activeTenant, resolvedPublicSite])

  const portalUrlUnavailable =
    revealOpen && !bootstrapUrl && !resolvingPublicSite && resolvedPublicSite?.site_configured !== false

  const query = useMemo<PortalAccessOverviewQuery>(
    () => ({
      siteId: effectiveSiteId || null,
      departmentId: filterDepartmentId || null,
      employeeStatus: filterEmployeeStatus || 'active',
      portalFilter: portalFilter || null,
      search: search || null,
      sort,
      sortDir,
      limit: PAGE_SIZE,
      offset: page * PAGE_SIZE,
    }),
    [
      effectiveSiteId,
      filterDepartmentId,
      filterEmployeeStatus,
      portalFilter,
      search,
      sort,
      sortDir,
      page,
    ],
  )

  const sitePillOptions = useMemo((): FilterPillOption[] => {
    if (sites.length <= 1 || selectedSiteId) return []
    return sites.map((s) => ({
      id: s.id,
      label: s.name,
      count: allEmployees.filter((e) => e.site_id === s.id).length,
    }))
  }, [sites, selectedSiteId, allEmployees])

  const departmentPillOptions = useMemo((): FilterPillOption[] => {
    return departments
      .filter((d) => d.id)
      .map((d) => ({
        id: d.id!,
        label: d.name ?? d.id!,
        count: allEmployees.filter(
          (e) =>
            e.department_id === d.id &&
            (!effectiveSiteId || e.site_id === effectiveSiteId),
        ).length,
      }))
      .filter((o) => o.count > 0)
  }, [departments, allEmployees, effectiveSiteId])

  const { data, isLoading, error, refetch } = useEmployeePortalOverview(query)
  const rows = data?.rows ?? []
  const summary = data?.summary
  const total = data?.total ?? 0
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))

  useEffect(() => {
    onSubtitleChange?.(summary?.total_employees ?? total)
  }, [onSubtitleChange, summary?.total_employees, total])

  useEffect(() => {
    if (!createOpen && !revealOpen && !regenerateToken && !revokeToken) {
      setRowActionEmployee(null)
    }
  }, [createOpen, revealOpen, regenerateToken, revokeToken])

  const selectableIds = useMemo(
    () =>
      rows
        .filter((row) => row.status === 'active' && hasEmployeeDocumentId(row.document_id))
        .map((row) => row.employee_id),
    [rows],
  )

  const selectedEmployees = useMemo(
    () =>
      rows
        .filter((row) => selectedIds.has(row.employee_id))
        .map((row) => ({ id: row.employee_id })),
    [rows, selectedIds],
  )

  const toggleEmployeeSelection = useCallback((employeeId: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(employeeId)) next.delete(employeeId)
      else next.add(employeeId)
      return next
    })
  }, [])

  const toggleSelectAll = useCallback((employeeIds: string[], selected: boolean) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      for (const id of employeeIds) {
        if (selected) next.add(id)
        else next.delete(id)
      }
      return next
    })
  }, [])

  function applyQuickFilter(filter: PortalAccessOverviewPortalFilter | '') {
    setPortalFilter(filter)
    setPage(0)
  }

  function handleBatchCompleted(payload: {
    start: StartPortalTokenBatchResult
    results: FetchPortalTokenBatchResults | null
  }) {
    setBatchStart(payload.start)
    setBatchResults(payload.results)
    setBatchResultsOpen(true)
    setSelectedIds(new Set())
    void refetch()
  }

  function handleBatchRecover(payload: {
    start: StartPortalTokenBatchResult
    results: FetchPortalTokenBatchResults
  }) {
    setBatchStart(payload.start)
    setBatchResults(payload.results)
    setBatchResultsOpen(true)
  }

  async function refreshOverview() {
    await queryClient.invalidateQueries({ queryKey: ['employee-portal-overview'] })
    await refetch()
  }

  function openGeneratePersonal(row: PortalAccessOverviewRow) {
    setRowActionEmployee(row)
    setCreateOpen(true)
  }

  function openSendEmail(row: PortalAccessOverviewRow) {
    setRowActionEmployee(row)
    setRegenerateError(null)
    setRegenerateSuccess(null)
    const tokenId = row.personal.token_id
    if (!tokenId) return

    void queryClient
      .fetchQuery({
        queryKey: employeePortalKeys.tokens(row.employee_id),
        queryFn: () => listEmployeePortalTokens(row.employee_id),
      })
      .then((tokens) => {
        const resolved = tokens.find(
          (item) => item.id === tokenId && isTokenActive(item),
        )
        if (resolved) setRegenerateToken(resolved)
      })
  }

  function openRevoke(row: PortalAccessOverviewRow) {
    setRowActionEmployee(row)
    setRevokeToken(overviewRowToRevokeToken(row))
  }

  async function handleRegenerateAndSend(token: EmployeePortalToken) {
    if (!activeTenant || !rowActionEmployee?.email?.trim()) return

    setRegeneratePending(true)
    setRegenerateError(null)
    setRegenerateSuccess(null)
    try {
      const created = await createEmployeePortalToken({
        employeeId: rowActionEmployee.employee_id,
        ...buildRegenerateTokenInput(token),
      })
      await sendEmployeePortalAccessEmail({
        tenantId: activeTenant.id,
        employeeId: rowActionEmployee.employee_id,
        tokenId: created.tokenId,
        secret: created.secret,
        recipient: rowActionEmployee.email.trim(),
      })
      setRegenerateSuccess(
        t(
          'employees.portal_access.regenerate_sent',
          'S\'ha generat un nou enllaç i s\'ha enviat per correu a {{email}}. L\'enllaç anterior queda revocat.',
          { email: rowActionEmployee.email.trim() },
        ),
      )
      setRegenerateToken(null)
      await refreshOverview()
    } catch (err) {
      setRegenerateError(
        err instanceof Error
          ? err.message
          : t('employees.portal_access.regenerate_error', 'No s\'ha pogut regenerar i enviar l\'enllaç.'),
      )
    } finally {
      setRegeneratePending(false)
    }
  }

  const kpiItems = [
    {
      key: 'without_personal_link' as const,
      filter: 'no_personal_link' as const,
      label: t('employees.portal_hub.kpi_without_link', '{{count}} sense enllaç', {
        count: summary?.without_personal_link ?? 0,
      }),
    },
    {
      key: 'never_opened' as const,
      filter: 'never_opened' as const,
      label: t('employees.portal_hub.kpi_never_opened', '{{count}} mai oberts', {
        count: summary?.never_opened ?? 0,
      }),
    },
    {
      key: 'missing_document_id' as const,
      filter: 'missing_document_id' as const,
      label: t('employees.portal_hub.kpi_missing_document', '{{count}} sense DNI', {
        count: summary?.missing_document_id ?? 0,
      }),
    },
  ]

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <p className="text-sm text-muted-foreground max-w-3xl">
          {t(
            'employees.portal_hub.subtitle',
            'Estat dels enllaços d\'empleat i generació per onboarding.',
          )}
        </p>
        {summary ? (
          <div className="flex flex-wrap gap-2 pt-2">
            <button
              type="button"
              className={`text-sm rounded-full border px-3 py-1 transition-colors ${
                portalFilter === ''
                  ? 'bg-primary/10 border-primary/30 text-primary'
                  : 'hover:bg-muted'
              }`}
              onClick={() => applyQuickFilter('')}
            >
              {t('employees.portal_hub.kpi_active', '{{count}} actius', {
                count: summary.total_employees,
              })}
            </button>
            {kpiItems.map((item) => (
              <button
                key={item.key}
                type="button"
                className={`text-sm rounded-full border px-3 py-1 transition-colors ${
                  portalFilter === item.filter
                    ? 'bg-primary/10 border-primary/30 text-primary'
                    : 'hover:bg-muted'
                }`}
                onClick={() => applyQuickFilter(item.filter)}
              >
                {item.label}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      <PortalTokenBatchRecoveryBanner onRecover={handleBatchRecover} />

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setRecentBatchesOpen(true)}
            className="gap-2"
          >
            <History className="h-4 w-4" />
            {t('employees.portal_hub.imports_recent', 'Importacions recents')}
          </Button>
        </div>
        <PortalAccessHubHelp />
      </div>

      {regenerateSuccess ? (
        <p className="text-sm text-emerald-700 dark:text-emerald-400 rounded-md border border-emerald-500/40 bg-emerald-50 dark:bg-emerald-950/20 px-3 py-2">
          {regenerateSuccess}
        </p>
      ) : null}

      {regenerateError ? (
        <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
          {regenerateError}
        </p>
      ) : null}

      {selectedIds.size > 0 ? (
        <div className="sticky top-2 z-10 rounded-xl border border-primary/30 bg-card shadow-sm px-4 py-3 flex flex-col sm:flex-row sm:items-center gap-3">
          <p className="text-sm flex-1">
            {t('employees.batch.selected_count', '{{count}} empleats seleccionats', {
              count: selectedIds.size,
            })}
          </p>
          <Button
            className="gap-2 shrink-0"
            onClick={() => setBatchDialogOpen(true)}
            disabled={selectedIds.size > 100}
          >
            <Link2 className="h-4 w-4" />
            {t('employees.portal_hub.generate_selected', 'Generar accés (seleccionats)')}
          </Button>
          <Button
            variant="ghost"
            size="icon"
            onClick={() => setSelectedIds(new Set())}
            aria-label={t('employees.batch.cancel_selection', 'Cancel·lar selecció')}
          >
            <X className="h-4 w-4" />
          </Button>
        </div>
      ) : null}

      <div className="space-y-3">
        {sitePillOptions.length > 0 ? (
          <FilterPillRow
            label={t('employees.filter.site_label', 'Local')}
            value={filterSiteId}
            onChange={(id) => {
              setFilterSiteId(id)
              setFilterDepartmentId('')
              setPage(0)
            }}
            allLabel={t('employees.filter.all_sites', 'Tots els locals')}
            options={sitePillOptions}
            testId="portal-access-filter-sites"
          />
        ) : null}
        {departmentPillOptions.length > 0 ? (
          <FilterPillRow
            label={t('employees.filter.department_label', 'Departament')}
            value={filterDepartmentId}
            onChange={(id) => {
              setFilterDepartmentId(id)
              setPage(0)
            }}
            allLabel={t('employees.filter.all_departments', 'Tots')}
            options={departmentPillOptions}
            testId="portal-access-filter-departments"
          />
        ) : null}

        <div className="flex flex-wrap gap-3 items-center">
          <Input
            value={search}
            onChange={(e) => {
              setSearch(e.target.value)
              setPage(0)
            }}
            placeholder={t('employees.filter.search_placeholder', 'Cerca per nom, email o document…')}
            className="w-56"
            data-testid="portal-access-search"
          />
          <select
            value={filterEmployeeStatus}
            onChange={(e) => {
              setFilterEmployeeStatus(e.target.value)
              setPage(0)
            }}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
            aria-label={t('employees.filter.status_label', 'Filtrar per estat')}
            data-testid="portal-access-employee-status"
          >
            <option value="all">{t('employees.filter.all_statuses', 'Tots els estats')}</option>
            <option value="active">{t('employees.status.active', 'Actiu')}</option>
            <option value="inactive">{t('employees.status.inactive', 'Inactiu')}</option>
            <option value="terminated">{t('employees.status.terminated', 'Baixa')}</option>
          </select>
          <select
            value={portalFilter}
            onChange={(e) => {
              setPortalFilter(e.target.value as PortalAccessOverviewPortalFilter | '')
              setPage(0)
            }}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
            aria-label={t('employees.portal_hub.filter_portal_status', 'Estat portal')}
            data-testid="portal-access-filter"
          >
            <option value="">
              {t('employees.portal_hub.filter_portal_all', 'Tots els estats portal')}
            </option>
            <option value="no_personal_link">
              {t('employees.portal_hub.filter_no_personal', 'Sense enllaç personal')}
            </option>
            <option value="has_personal_link">
              {t('employees.portal_hub.filter_has_personal', 'Amb enllaç actiu')}
            </option>
            <option value="never_opened">
              {t('employees.portal_hub.filter_never_opened', 'Mai obert')}
            </option>
            <option value="pin_not_configured">
              {t('employees.portal_hub.filter_pin_pending', 'PIN pendent')}
            </option>
            <option value="missing_document_id">
              {t('employees.portal_hub.filter_missing_document', 'Sense DNI')}
            </option>
          </select>
          <select
            value={sort}
            onChange={(e) => {
              setSort(e.target.value as PortalAccessOverviewSort)
              setPage(0)
            }}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
            aria-label={t('employees.portal_hub.sort_label', 'Ordenar per')}
          >
            <option value="name">{t('employees.portal_hub.sort_name', 'Nom')}</option>
            <option value="last_access">
              {t('employees.portal_hub.sort_last_access', 'Últim accés')}
            </option>
            <option value="link_created">
              {t('employees.portal_hub.sort_link_created', 'Data creació enllaç')}
            </option>
          </select>
          <select
            value={sortDir}
            onChange={(e) => {
              setSortDir(e.target.value as 'asc' | 'desc')
              setPage(0)
            }}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
            aria-label={t('employees.portal_hub.sort_dir_label', 'Direcció')}
          >
            <option value="asc">{t('employees.portal_hub.sort_dir_asc', 'Ascendent')}</option>
            <option value="desc">{t('employees.portal_hub.sort_dir_desc', 'Descendent')}</option>
          </select>

          <div
            className="ml-auto inline-flex rounded-lg border bg-muted/40 p-0.5"
            role="group"
            aria-label={t('employees.portal_hub.view_label', 'Vista')}
          >
            <Button
              type="button"
              variant={viewMode === 'cards' ? 'secondary' : 'ghost'}
              size="sm"
              className="h-8 gap-1.5 px-2.5"
              onClick={() => setViewMode('cards')}
              aria-pressed={viewMode === 'cards'}
              data-testid="portal-access-view-cards"
            >
              <LayoutGrid className="h-3.5 w-3.5" />
              {t('employees.view.avatar_cards', 'Targetes')}
            </Button>
            <Button
              type="button"
              variant={viewMode === 'table' ? 'secondary' : 'ghost'}
              size="sm"
              className="h-8 gap-1.5 px-2.5"
              onClick={() => setViewMode('table')}
              aria-pressed={viewMode === 'table'}
              data-testid="portal-access-view-table"
            >
              <List className="h-3.5 w-3.5" />
              {t('employees.view.list', 'Llista')}
            </Button>
          </div>
        </div>
      </div>

      {isLoading ? (
        <div className="flex items-center justify-center h-48">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
        </div>
      ) : error ? (
        <div className="rounded-xl border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm text-destructive">
          {t('employees.portal_hub.load_error', 'No s\'ha pogut carregar el resum d\'accés.')}
        </div>
      ) : (
        <>
          {viewMode === 'cards' ? (
            <PortalAccessOverviewCards
              rows={rows}
              selectedIds={selectedIds}
              selectableIds={selectableIds}
              onToggleSelect={toggleEmployeeSelection}
              onGeneratePersonal={openGeneratePersonal}
              onSendEmail={openSendEmail}
              onRevoke={openRevoke}
            />
          ) : (
            <PortalAccessOverviewTable
              rows={rows}
              selectedIds={selectedIds}
              onToggleSelect={toggleEmployeeSelection}
              onToggleSelectAll={toggleSelectAll}
              selectableIds={selectableIds}
              onGeneratePersonal={openGeneratePersonal}
              onSendEmail={openSendEmail}
              onRevoke={openRevoke}
            />
          )}
          {total > PAGE_SIZE ? (
            <div className="flex items-center justify-between gap-3 text-sm">
              <p className="text-muted-foreground">
                {t('employees.portal_hub.pagination', 'Pàgina {{page}} de {{total}}', {
                  page: page + 1,
                  total: totalPages,
                })}
              </p>
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  disabled={page <= 0}
                  onClick={() => setPage((p) => Math.max(0, p - 1))}
                >
                  <ChevronLeft className="h-4 w-4" />
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  disabled={page + 1 >= totalPages}
                  onClick={() => setPage((p) => p + 1)}
                >
                  <ChevronRight className="h-4 w-4" />
                </Button>
              </div>
            </div>
          ) : null}
        </>
      )}

      <PortalTokenBatchDialog
        open={batchDialogOpen}
        onOpenChange={setBatchDialogOpen}
        employees={selectedEmployees}
        onCompleted={handleBatchCompleted}
      />

      <PortalTokenBatchResultsDialog
        open={batchResultsOpen}
        onOpenChange={setBatchResultsOpen}
        start={batchStart}
        results={batchResults}
        onOpenRecentBatches={() => {
          setBatchResultsOpen(false)
          setRecentBatchesOpen(true)
        }}
      />

      <PortalTokenBatchRecentDialog
        open={recentBatchesOpen}
        onOpenChange={setRecentBatchesOpen}
        onRecover={handleBatchRecover}
      />

      {rowActionEmployee ? (
        <CreatePortalTokenDialog
          open={createOpen}
          onOpenChange={setCreateOpen}
          employeeId={rowActionEmployee.employee_id}
          employeeActive={rowActionEmployee.status === 'active'}
          employeeDocumentId={rowActionEmployee.document_id}
          existingTokens={rowActionTokens}
          onCreated={({ tokenId, secret, supersededTokenId, label }) => {
            setRevealSecret(secret)
            setRevealTokenId(tokenId)
            setRevealLabel(label)
            setRevealSuperseded(Boolean(supersededTokenId))
            setRevealOpen(true)
            void refreshOverview()
          }}
        />
      ) : null}

      {rowActionEmployee ? (
        <PortalTokenRevealDialog
          open={revealOpen}
          onOpenChange={(open) => {
            setRevealOpen(open)
            if (!open) {
              setRevealSecret('')
              setRevealTokenId('')
              setRevealLabel('')
              setRevealSuperseded(false)
            }
          }}
          bootstrapUrl={bootstrapUrl}
          employeeName={rowActionEmployee.full_name ?? undefined}
          employeeCode={rowActionEmployee.document_id}
          tokenLabel={revealLabel}
          supersededPreviousLink={revealSuperseded}
          urlUnavailable={portalUrlUnavailable}
          tenantId={activeTenant?.id}
          employeeId={rowActionEmployee.employee_id}
          tokenId={revealTokenId}
          secret={revealSecret}
          employeeEmail={rowActionEmployee.email}
        />
      ) : null}

      <Dialog
        open={!!regenerateToken}
        onOpenChange={(open) => {
          if (!open && !regeneratePending) {
            setRegenerateToken(null)
            setRegenerateError(null)
          }
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.regenerate_title', 'Regenerar i enviar per correu')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'employees.portal_access.regenerate_description',
                'Es generarà un nou enllaç, es revocarà l\'actiu del mateix tipus i s\'enviarà per correu a {{email}}. L\'URL no es mostrarà a pantalla.',
                { email: rowActionEmployee?.email?.trim() ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setRegenerateToken(null)}
              disabled={regeneratePending}
            >
              {t('employees.portal_access.email_cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              onClick={() => regenerateToken && void handleRegenerateAndSend(regenerateToken)}
              disabled={regeneratePending || !regenerateToken}
            >
              {regeneratePending ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Mail className="h-4 w-4 mr-2" />
              )}
              {t('employees.portal_access.regenerate_confirm', 'Regenerar i enviar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {rowActionEmployee ? (
        <RevokePortalTokenDialog
          open={!!revokeToken}
          onOpenChange={(open) => {
            if (!open) {
              setRevokeToken(null)
              void refreshOverview()
            }
          }}
          employeeId={rowActionEmployee.employee_id}
          token={revokeToken}
        />
      ) : null}
    </div>
  )
}
