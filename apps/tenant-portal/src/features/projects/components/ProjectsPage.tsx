import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useSearchParams } from 'react-router-dom'
import { Plus, ClipboardList, AlertTriangle, Search, X, ChevronLeft, ChevronRight, ArrowUpDown, ArrowUp, ArrowDown, SlidersHorizontal } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { useProjects } from '../api/useProjects'
import { ProjectRow } from './ProjectRow'
import { ProjectForm } from './ProjectForm'
import type { Project } from '../api/projectsService'
import { useDebounce } from '@/hooks/useDebounce'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'
import { useWorkLog } from '../api/useWorkLog'
import { useProjectsWorkLogTotals } from '../api/useProjectWorkLogSummary'
import { cn } from '@/lib/utils'
import { localDayRange, plannedDateRangeBounds, type PlannedDateRangeKey } from '@/lib/dateLocal'

const PAGE_SIZE_OPTIONS = [10, 20, 50] as const
const SORT_FIELDS = ['created_at', 'name', 'type', 'status', 'planned_start', 'task_count'] as const
const FS_SCOPE_FILTERS = ['all', 'mine', 'open'] as const
const FS_DATE_RANGES: PlannedDateRangeKey[] = ['today', 'this_week', 'last_week', 'month']
const PROJECT_TYPES = ['internal', 'work_order', 'maintenance'] as const

function FilterPill({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: ReactNode
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'rounded-full border px-3 py-1.5 text-xs font-medium transition-colors',
        active
          ? 'border-primary bg-primary text-primary-foreground'
          : 'border-border bg-background text-muted-foreground hover:text-foreground',
      )}
    >
      {children}
    </button>
  )
}

type SortField = (typeof SORT_FIELDS)[number]
type SortDirection = 'asc' | 'desc'

function parseIntParam(value: string | null, fallback: number): number {
  const parsed = Number.parseInt(value ?? '', 10)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

function parseSortField(value: string | null): SortField {
  return SORT_FIELDS.includes(value as SortField) ? (value as SortField) : 'created_at'
}

function parseSortDirection(value: string | null): SortDirection {
  return value === 'asc' ? 'asc' : 'desc'
}

function expandDateBound(value: string, endOfDay: boolean): string {
  if (!value) return ''
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const range = localDayRange(value)
    return endOfDay ? range.to : range.from
  }
  return value
}

interface ProjectsPageProps {
  fieldServiceMode?: boolean
}

export function ProjectsPage({ fieldServiceMode = false }: ProjectsPageProps) {
  const { t } = useTranslation(['projects', 'field-service'])
  const { toast } = useToast()
  const { user } = useAuth()
  const { activeTenant, tenantsLoading, sites } = useTenant()
  const [searchParams, setSearchParams] = useSearchParams()
  const { data: departments = [] } = useDepartments()
  const isFieldService = useIsFieldService() || fieldServiceMode
  const projectLabel = useSectorLabel('project', t('projects.list.title', 'Projectes'))
  const projectLabelPlural = useSectorLabel(
    'project_plural',
    isFieldService ? t('field-service:orders.title', 'Ordres de servei') : projectLabel,
  )

  const { openLogInOtherProject } = useWorkLog(null)
  const activePunchProjectId = isFieldService
    ? (openLogInOtherProject?.project_id ?? null)
    : null
  const {
    stopWorkLog,
    isStopping,
    isCapturingGeo,
    openLog: activeOpenLog,
  } = useWorkLog(activePunchProjectId)
  const stopPunchBusy = isStopping || isCapturingGeo || (!!activePunchProjectId && !activeOpenLog?.id)

  async function handleStopActivePunch() {
    if (!activePunchProjectId || !activeOpenLog?.id) return
    try {
      const result = await stopWorkLog()
      toast({
        description: result.mode === 'offline'
          ? t('projects.worklog.toast_stop_offline', 'Aturada desada en local (offline)')
          : t('projects.worklog.toast_stop_online', 'Fitxatge aturat'),
      })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({ variant: 'destructive', description: msg })
    }
  }

  const [formOpen, setFormOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Project | null>(null)
  const [searchDraft, setSearchDraft] = useState(searchParams.get('q') ?? '')
  const [initialClientId, setInitialClientId] = useState<string | null>(null)
  const [initialContactSiteId, setInitialContactSiteId] = useState<string | null>(null)
  const [filtersOpen, setFiltersOpen] = useState(false)

  const fsQuickFilter = searchParams.get('fsFilter') ?? (fieldServiceMode ? 'all' : '')

  const page = parseIntParam(searchParams.get('page'), 1)
  const pageSize = parseIntParam(searchParams.get('pageSize'), 20)
  const status = searchParams.get('status') ?? ''
  const rawType = searchParams.get('type')
  // FS: default work_order; use type=all for "Tots els tipus" (empty would fall back to default).
  const type = fieldServiceMode
    ? rawType === 'all'
      ? ''
      : (rawType ?? 'work_order')
    : (rawType ?? '')
  const siteId = searchParams.get('siteId') ?? ''
  const departmentId = searchParams.get('departmentId') ?? ''
  const plannedStartFrom = searchParams.get('plannedStartFrom') ?? ''
  const plannedStartTo = searchParams.get('plannedStartTo') ?? ''
  const dateRange = searchParams.get('dateRange') ?? ''
  const sortField = parseSortField(searchParams.get('sortField'))
  const sortDirection = parseSortDirection(searchParams.get('sortDirection'))
  const debouncedSearch = useDebounce(searchDraft, 300)

  useEffect(() => {
    const shouldCreate = searchParams.get('create') === '1'
    if (!shouldCreate) return

    const clientId = searchParams.get('client_id')
    setInitialClientId(clientId)
    setInitialContactSiteId(searchParams.get('contact_site_id'))
    setEditTarget(null)
    setFormOpen(true)

    const next = new URLSearchParams(searchParams)
    next.delete('create')
    setSearchParams(next, { replace: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams.get('create')])

  useEffect(() => {
    const nextQ = searchParams.get('q') ?? ''
    if (nextQ !== searchDraft) setSearchDraft(nextQ)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams])

  useEffect(() => {
    const currentQ = searchParams.get('q') ?? ''
    if (debouncedSearch === currentQ) return

    const next = new URLSearchParams(searchParams)
    if (debouncedSearch.trim()) next.set('q', debouncedSearch.trim())
    else next.delete('q')
    next.set('page', '1')
    setSearchParams(next, { replace: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debouncedSearch])

  const projectQuery = useMemo(() => ({
    page,
    pageSize,
    q: searchParams.get('q') ?? '',
    status,
    type,
    siteId,
    departmentId,
    plannedStartFrom: expandDateBound(plannedStartFrom, false),
    plannedStartTo: expandDateBound(plannedStartTo, true),
    sortField,
    sortDirection,
    createdBy: isFieldService && fsQuickFilter === 'mine' ? (user?.id ?? undefined) : undefined,
    openOnly: isFieldService && fsQuickFilter === 'open',
  }), [
    page,
    pageSize,
    searchParams,
    status,
    type,
    siteId,
    departmentId,
    plannedStartFrom,
    plannedStartTo,
    sortField,
    sortDirection,
    isFieldService,
    fsQuickFilter,
    user?.id,
  ])

  const { data, isLoading, error, isFetching } = useProjects(projectQuery)
  const projects = data?.items ?? []
  const projectIds = useMemo(
    () => projects.map((p) => p.id).filter((id): id is string => !!id),
    [projects],
  )
  const { totals: workLogTotals } = useProjectsWorkLogTotals(
    isFieldService ? projectIds : [],
    isFieldService && activePunchProjectId
      ? {
          projectId: activePunchProjectId,
          checkIn: activeOpenLog?.check_in ?? openLogInOtherProject?.check_in ?? null,
        }
      : null,
  )
  const totalCount = data?.totalCount ?? 0
  const totalPages = Math.max(1, Math.ceil(totalCount / pageSize))
  const canGoPrev = page > 1
  const canGoNext = page < totalPages

  const hasSites = sites.length > 0
  const hasDepartments = departments.length > 0
  const prereqsReady = hasSites && hasDepartments

  function handleOpenCreate() {
    if (!prereqsReady) {
      toast({
        variant: 'destructive',
        description: !hasSites && !hasDepartments
          ? t('projects.prereq.missing_both', 'Cal crear almenys un local i un departament abans de crear projectes')
          : !hasSites
            ? t('projects.prereq.missing_sites', 'Cal crear almenys un local abans de crear projectes')
            : t('projects.prereq.missing_departments', 'Cal crear almenys un departament abans de crear projectes'),
      })
      return
    }
    setEditTarget(null)
    setFormOpen(true)
  }

  function handleEdit(project: Project) {
    setEditTarget(project)
    setFormOpen(true)
  }

  function handleCloseForm() {
    setFormOpen(false)
    setEditTarget(null)
  }

  function updateParam(name: string, value: string | number | null) {
    const next = new URLSearchParams(searchParams)
    if (value === null || value === '') next.delete(name)
    else next.set(name, String(value))
    next.set('page', '1')
    setSearchParams(next, { replace: true })
  }

  /** FS needs type=all so clearing does not fall back to default work_order. */
  function setTypeFilter(nextType: string) {
    updateParam('type', fieldServiceMode && !nextType ? 'all' : nextType)
  }

  function goToPage(nextPage: number) {
    const next = new URLSearchParams(searchParams)
    next.set('page', String(nextPage))
    setSearchParams(next, { replace: true })
  }

  function setFsQuickFilter(filter: string) {
    const next = new URLSearchParams(searchParams)
    if (!filter || filter === 'all') next.delete('fsFilter')
    else next.set('fsFilter', filter)

    if (filter === 'open' && !next.get('type')) {
      next.set('type', 'work_order')
    }

    next.set('page', '1')
    setSearchParams(next, { replace: true })
  }

  function setDateRangeFilter(key: PlannedDateRangeKey | '') {
    const next = new URLSearchParams(searchParams)
    if (!key) {
      next.delete('dateRange')
      next.delete('plannedStartFrom')
      next.delete('plannedStartTo')
    } else {
      const bounds = plannedDateRangeBounds(key)
      next.set('dateRange', key)
      next.set('plannedStartFrom', bounds.from)
      next.set('plannedStartTo', bounds.to)
    }
    next.set('page', '1')
    setSearchParams(next, { replace: true })
  }

  function clearFilters() {
    const next = new URLSearchParams()
    next.set('pageSize', String(pageSize))
    next.set('sortField', sortField)
    next.set('sortDirection', sortDirection)
    setSearchDraft('')
    setSearchParams(next, { replace: true })
  }

  function toggleSort(field: SortField) {
    const next = new URLSearchParams(searchParams)
    const isCurrentField = sortField === field
    const nextDirection: SortDirection = isCurrentField && sortDirection === 'asc' ? 'desc' : 'asc'
    next.set('sortField', field)
    next.set('sortDirection', nextDirection)
    next.set('page', '1')
    setSearchParams(next, { replace: true })
  }

  function SortButton({ field, label, className = '' }: { field: SortField; label: string; className?: string }) {
    const active = sortField === field
    const icon = active ? (sortDirection === 'asc' ? <ArrowUp className="ml-1 h-3.5 w-3.5" /> : <ArrowDown className="ml-1 h-3.5 w-3.5" />) : <ArrowUpDown className="ml-1 h-3.5 w-3.5 opacity-60" />

    return (
      <button
        type="button"
        onClick={() => toggleSort(field)}
        className={['inline-flex items-center font-medium hover:text-foreground', className, active ? 'text-foreground' : ''].join(' ')}
      >
        {label}
        {icon}
      </button>
    )
  }

  const activeFilterCount = [
    searchParams.get('q'),
    status,
    isFieldService ? '' : type,
    siteId,
    departmentId,
    plannedStartFrom,
    plannedStartTo,
    isFieldService && fsQuickFilter && fsQuickFilter !== 'all' ? fsQuickFilter : '',
  ].filter(Boolean).length

  if (tenantsLoading || isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      </div>
    )
  }

  if (!activeTenant) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-muted-foreground gap-2">
        <ClipboardList className="h-10 w-10 opacity-40" />
        <p>{t('projects.errors.no_tenant', 'Selecciona una organització per veure els projectes')}</p>
      </div>
    )
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-destructive gap-2">
        <p>{t('projects.errors.load_failed', 'Error en carregar els projectes')}</p>
      </div>
    )
  }

  return (
    <div className={cn('mx-auto max-w-7xl space-y-5', fieldServiceMode ? 'p-4 pb-24' : 'p-6')}>
      {fieldServiceMode ? (
        <div className="flex items-center justify-between gap-4">
          <div className="space-y-1 min-w-0">
            <h1 className="text-xl sm:text-2xl font-bold text-foreground">{projectLabelPlural}</h1>
            <p className="text-sm text-muted-foreground">
              {t('field-service:orders.subtitle', 'Les teves ordres i visites')}
            </p>
          </div>
          <Button
            onClick={handleOpenCreate}
            className="gap-2 hidden sm:inline-flex shrink-0"
            disabled={!prereqsReady}
          >
            <Plus className="h-4 w-4" />
            {t('field-service:orders.new', 'Nova ordre')}
          </Button>
        </div>
      ) : (
        <div className="flex flex-col gap-4 rounded-2xl border border-border bg-card p-5 shadow-sm lg:flex-row lg:items-end lg:justify-between">
          <div className="space-y-1">
            <h1 className="text-2xl font-bold text-foreground">{projectLabelPlural}</h1>
            <p className="text-sm text-muted-foreground">
              {t('projects.list.subtitle', 'Gestiona els projectes i ordres de treball')}
            </p>
          </div>
          <Button onClick={handleOpenCreate} className="gap-2 self-start" disabled={!prereqsReady} title={!prereqsReady ? t('projects.prereq.button_disabled_title', 'Cal configurar locals i departaments primer') : undefined}>
            <Plus className="h-4 w-4" />
            {t('projects.list.new', 'Nou projecte')}
          </Button>
        </div>
      )}

      {fieldServiceMode && (
        <div className="sm:hidden fixed bottom-[calc(4.5rem+env(safe-area-inset-bottom))] right-4 z-30">
          <Button
            size="icon"
            className="h-14 w-14 rounded-full shadow-lg"
            onClick={handleOpenCreate}
            disabled={!prereqsReady}
            aria-label={t('field-service:orders.new', 'Nova ordre')}
          >
            <Plus className="h-6 w-6" />
          </Button>
        </div>
      )}

      {isFieldService && (
        <div className="flex flex-wrap gap-2">
          {FS_SCOPE_FILTERS.map((filter) => (
            <FilterPill
              key={filter}
              active={(fsQuickFilter || 'all') === filter}
              onClick={() => setFsQuickFilter(filter)}
            >
              {t(`field-service:orders.filter_${filter}`, filter)}
            </FilterPill>
          ))}
        </div>
      )}

      <div className={cn('space-y-3', !fieldServiceMode && 'rounded-2xl border border-border bg-card p-3 shadow-sm')}>
        <div className="flex items-center gap-2">
          <div className="relative flex-1 min-w-0">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={searchDraft}
              onChange={(e) => setSearchDraft(e.target.value)}
              placeholder={t('projects.filters.search_placeholder', 'Cerca per nom o descripció')}
              className="pl-9"
              aria-label={t('projects.filters.search_placeholder', 'Cerca per nom o descripció')}
            />
          </div>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="shrink-0 md:hidden"
            onClick={() => setFiltersOpen((v) => !v)}
            aria-expanded={filtersOpen}
            aria-label={t('projects.filters.toggle', 'Filtres')}
          >
            <SlidersHorizontal className="h-4 w-4" />
          </Button>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="shrink-0"
            onClick={clearFilters}
            disabled={activeFilterCount === 0}
            aria-label={t('projects.filters.clear', 'Netejar')}
          >
            <X className="h-4 w-4" />
          </Button>
        </div>

        {isFieldService && (
          <div className={cn('space-y-3', !filtersOpen && 'hidden md:block')}>
            <div className="flex flex-wrap gap-2">
              {FS_DATE_RANGES.map((rangeKey) => (
                <FilterPill
                  key={rangeKey}
                  active={dateRange === rangeKey}
                  onClick={() => setDateRangeFilter(dateRange === rangeKey ? '' : rangeKey)}
                >
                  {t(`field-service:orders.date_${rangeKey}`, rangeKey)}
                </FilterPill>
              ))}
            </div>
            <div className="flex flex-wrap gap-2">
              <FilterPill active={!type} onClick={() => setTypeFilter('')}>
                {t('projects.filters.all_types', 'Tots els tipus')}
              </FilterPill>
              {PROJECT_TYPES.map((projectType) => (
                <FilterPill
                  key={projectType}
                  active={type === projectType}
                  onClick={() => setTypeFilter(type === projectType ? '' : projectType)}
                >
                  {t(`projects.type.${projectType}`, projectType)}
                </FilterPill>
              ))}
            </div>
            {sites.length > 1 && (
              <div className="flex flex-wrap gap-2">
                <FilterPill active={!siteId} onClick={() => updateParam('siteId', '')}>
                  {t('projects.filters.all_sites', 'Tots els locals')}
                </FilterPill>
                {sites.map((site) => (
                  <FilterPill
                    key={site.id}
                    active={siteId === site.id}
                    onClick={() => updateParam('siteId', siteId === site.id ? '' : site.id)}
                  >
                    {site.name}
                  </FilterPill>
                ))}
              </div>
            )}
          </div>
        )}

        {activeFilterCount > 0 && (
          <div className="hidden md:flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            {searchDraft.trim() && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{searchDraft.trim()}</Badge>}
            {status && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{t(`projects.status.${status}`, status)}</Badge>}
            {!isFieldService && type && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{t(`projects.type.${type}`, type)}</Badge>}
            {siteId && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{sites.find((site) => site.id === siteId)?.name ?? siteId}</Badge>}
            {departmentId && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{departments.find((department) => department.id === departmentId)?.name ?? departmentId}</Badge>}
            {plannedStartFrom && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{plannedStartFrom}</Badge>}
            {plannedStartTo && <Badge variant="secondary" className="rounded-full px-2.5 py-1 text-xs">{plannedStartTo}</Badge>}
          </div>
        )}

        <div
          className={cn(
            'grid gap-2 md:grid-cols-2 xl:grid-cols-6',
            !filtersOpen && 'hidden md:grid',
          )}
        >
          <select value={status} onChange={(e) => updateParam('status', e.target.value)} className="rounded-md border border-input bg-background px-3 py-2 text-sm">
            <option value="">{t('projects.filters.all_status', 'Tots els estats')}</option>
            <option value="draft">{t('projects.status.draft', 'Esborrany')}</option>
            <option value="in_progress">{t('projects.status.in_progress', 'En curs')}</option>
            <option value="active">{t('projects.status.active', 'Actiu')}</option>
            <option value="on_hold">{t('projects.status.on_hold', 'En espera')}</option>
            <option value="completed">{t('projects.status.completed', 'Completat')}</option>
            <option value="cancelled">{t('projects.status.cancelled', 'Cancel·lat')}</option>
          </select>

          {!isFieldService && (
            <select value={type} onChange={(e) => updateParam('type', e.target.value)} className="rounded-md border border-input bg-background px-3 py-2 text-sm">
              <option value="">{t('projects.filters.all_types', 'Tots els tipus')}</option>
              <option value="internal">{t('projects.type.internal', 'Intern')}</option>
              <option value="work_order">{t('projects.type.work_order', 'Ordre de treball')}</option>
              <option value="maintenance">{t('projects.type.maintenance', 'Manteniment')}</option>
            </select>
          )}

          {!isFieldService && sites.length > 1 && (
            <select value={siteId} onChange={(e) => updateParam('siteId', e.target.value)} className="rounded-md border border-input bg-background px-3 py-2 text-sm">
              <option value="">{t('projects.filters.all_sites', 'Tots els locals')}</option>
              {sites.map((site) => (
                <option key={site.id} value={site.id}>{site.name}</option>
              ))}
            </select>
          )}

          {departments.length > 1 && (
            <select value={departmentId} onChange={(e) => updateParam('departmentId', e.target.value)} className="rounded-md border border-input bg-background px-3 py-2 text-sm">
              <option value="">{t('projects.filters.all_departments', 'Tots els departaments')}</option>
              {departments.map((department) => (
                <option key={department.id} value={department.id!}>{department.name}</option>
              ))}
            </select>
          )}

          <div className="grid grid-cols-2 gap-2 xl:col-span-2">
            <Input type="date" value={plannedStartFrom} onChange={(e) => updateParam('plannedStartFrom', e.target.value)} aria-label={t('projects.filters.planned_from', 'Inici previst des de')} />
            <Input type="date" value={plannedStartTo} onChange={(e) => updateParam('plannedStartTo', e.target.value)} aria-label={t('projects.filters.planned_to', 'Inici previst fins a')} />
          </div>
        </div>
      </div>

      {/* Prereq warning banner */}
      {!prereqsReady && (
        <div className="mb-6 flex items-start gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm dark:border-amber-700 dark:bg-amber-950/40">
          <AlertTriangle className="h-5 w-5 shrink-0 text-amber-600 dark:text-amber-400 mt-0.5" />
          <div className="flex-1 space-y-1.5">
            <p className="font-medium text-amber-900 dark:text-amber-200">
              {t('projects.prereq.title', 'Configuració necessària')}
            </p>
            <p className="text-amber-800 dark:text-amber-300">
              {!hasSites && !hasDepartments
                ? t('projects.prereq.missing_both', 'Cal crear almenys un local i un departament abans de crear projectes')
                : !hasSites
                  ? t('projects.prereq.missing_sites', 'Cal crear almenys un local abans de crear projectes')
                  : t('projects.prereq.missing_departments', 'Cal crear almenys un departament abans de crear projectes')}
            </p>
            <div className="flex flex-wrap gap-2 pt-1">
              {!hasSites && (
                <Button asChild size="sm" variant="outline">
                  <Link to="/settings?section=locals">
                    {t('projects.prereq.go_sites', 'Configurar locals')}
                  </Link>
                </Button>
              )}
              {!hasDepartments && (
                <Button asChild size="sm" variant="outline">
                  <Link to="/departments">
                    {t('projects.prereq.go_departments', 'Configurar departaments')}
                  </Link>
                </Button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Results */}
      {projects.length === 0 ? (
        <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-border py-16 gap-3 text-center">
          <ClipboardList className="h-10 w-10 text-muted-foreground opacity-40" />
          <p className="text-muted-foreground text-sm">
            {activeFilterCount > 0
              ? (isFieldService
                ? t('field-service:orders.empty_filtered', 'No hi ha ordres amb aquests filtres')
                : t('projects.list.empty_filtered', 'No hi ha projectes amb aquests filtres'))
              : (isFieldService
                ? t('field-service:orders.empty', 'Encara no tens cap ordre de servei')
                : t('projects.list.empty', 'Encara no tens cap projecte'))}
          </p>
          <Button variant="outline" size="sm" onClick={handleOpenCreate} disabled={!prereqsReady}>
            {isFieldService
              ? t('field-service:orders.empty_cta', 'Crea la primera ordre')
              : t('projects.list.empty_cta', 'Crea el primer projecte')}
          </Button>
        </div>
      ) : (
        <div className="rounded-2xl border border-border overflow-hidden bg-card shadow-sm">
          <div className="flex items-center justify-between gap-3 border-b border-border px-4 py-3 text-sm text-muted-foreground">
            <span>
              {isFieldService
                ? t('field-service:orders.summary', '{{count}} ordres', { count: totalCount })
                : t('projects.list.summary', '{{count}} projectes', { count: totalCount })}
            </span>
            <span>
              {isFetching ? t('projects.list.refreshing', 'Actualitzant…') : t('projects.list.page', 'Pàgina {{page}} de {{total}}', { page, total: totalPages })}
            </span>
          </div>
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-muted-foreground">
              <tr>
                <th className="px-4 py-3 text-left font-medium">
                  <SortButton field="name" label={t('projects.list.col_name', 'Nom')} />
                </th>
                <th className="px-4 py-3 text-left font-medium hidden md:table-cell">
                  <SortButton field="type" label={t('projects.list.col_type', 'Tipus')} />
                </th>
                <th className="px-4 py-3 text-left font-medium hidden sm:table-cell">
                  <SortButton field="status" label={t('projects.list.col_status', 'Estat')} />
                </th>
                <th className="px-4 py-3 text-left font-medium hidden lg:table-cell">
                  <SortButton field="task_count" label={t('projects.list.col_tasks', 'Tasques')} />
                </th>
                <th className="px-4 py-3 text-right font-medium">
                  {t('projects.list.col_actions', 'Accions')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {projects.map((project) => (
                <ProjectRow
                  key={project.id}
                  project={project}
                  onEdit={handleEdit}
                  detailBasePath={isFieldService ? '/field/orders' : '/projects'}
                  activePunchProjectId={activePunchProjectId}
                  onStopPunch={() => { void handleStopActivePunch() }}
                  stopPunchBusy={stopPunchBusy}
                  workedSeconds={project.id ? (workLogTotals.get(project.id) ?? 0) : 0}
                />
              ))}
            </tbody>
          </table>

          <div className="flex flex-col gap-3 border-t border-border px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <span>{t('projects.list.page_size', 'Per pàgina')}</span>
              <select
                value={pageSize}
                onChange={(e) => updateParam('pageSize', Number(e.target.value))}
                className="rounded-md border border-input bg-background px-2 py-1 text-sm"
              >
                {PAGE_SIZE_OPTIONS.map((option) => (
                  <option key={option} value={option}>{option}</option>
                ))}
              </select>
              <span>{t('projects.list.results_range', '{{from}}-{{to}} de {{total}}', {
                from: totalCount === 0 ? 0 : ((page - 1) * pageSize) + 1,
                to: Math.min(page * pageSize, totalCount),
                total: totalCount,
              })}</span>
            </div>
            <div className="flex items-center gap-2 self-end sm:self-auto">
              <Button type="button" variant="outline" size="sm" onClick={() => goToPage(page - 1)} disabled={!canGoPrev}>
                <ChevronLeft className="mr-1 h-4 w-4" />
                {t('projects.list.prev', 'Anterior')}
              </Button>
              <Button type="button" variant="outline" size="sm" onClick={() => goToPage(page + 1)} disabled={!canGoNext}>
                {t('projects.list.next', 'Següent')}
                <ChevronRight className="ml-1 h-4 w-4" />
              </Button>
            </div>
          </div>
        </div>
      )}

      <ProjectForm
        open={formOpen}
        onClose={handleCloseForm}
        editProject={editTarget}
        initialClientId={initialClientId}
        initialContactSiteId={initialContactSiteId}
      />
    </div>
  )
}
