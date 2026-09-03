import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LayoutGrid, List, Plus, Upload, Users, ImageIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { cn } from '@/lib/utils'
import { useTenant } from '@/contexts/TenantContext'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { useEmployees } from '../api/useEmployees'
import type { Employee } from '../api/employeesService'
import type { EmployeeStatus } from '../schemas/employeeSchema'
import { EMPLOYEE_STATUSES } from '../schemas/employeeSchema'
import { useJobPositions } from '../api/useJobPositions'
import { jobPlaceName } from '../utils/jobPlaceName'
import { EmployeeRow } from './EmployeeRow'
import { EmployeeCard, type EmployeeCardVariant } from './EmployeeCard'
import { EmployeeForm } from './EmployeeForm'
import { EmployeeImportCsvDialog } from './EmployeeImportCsvDialog'
import { FilterPillRow, type FilterPillOption } from './EmployeeFilterPills'
import { Link } from 'react-router-dom'
import { useCanManageEmployeePortal } from '@/features/employee-portal/api/useCanManageEmployeePortal'
import {
  portalStatusForEmployee,
  useEmployeePortalStatusMap,
} from '@/features/employee-portal/api/useEmployeePortalStatusMap'

type DirectoryView = 'list' | 'avatar' | 'photo'

const VIEW_STORAGE_KEY = 'employees.directoryView'

function readStoredView(): DirectoryView {
  try {
    const v = localStorage.getItem(VIEW_STORAGE_KEY)
    if (v === 'avatar' || v === 'photo' || v === 'list') return v
    if (v === 'cards') return 'avatar'
  } catch {
    /* ignore */
  }
  return 'avatar'
}

interface EmployeesListTabProps {
  canWrite: boolean
}

export function EmployeesListTab({ canWrite }: EmployeesListTabProps) {
  const { t } = useTranslation('employees')
  const { sites, selectedSiteId } = useTenant()
  const { data: allEmployees = [], isLoading, error } = useEmployees()
  const { data: departments = [] } = useDepartments()
  const { data: jobPositions = [] } = useJobPositions(true)
  const canManagePortal = useCanManageEmployeePortal()
  const { statusByEmployeeId } = useEmployeePortalStatusMap(canManagePortal)

  const [formOpen, setFormOpen] = useState(false)
  const [importOpen, setImportOpen] = useState(false)
  const [editTarget, setEditTarget] = useState<Employee | null>(null)
  const [filterStatus, setFilterStatus] = useState<EmployeeStatus | 'all'>('all')
  const [filterDepartmentId, setFilterDepartmentId] = useState('')
  const [filterSiteId, setFilterSiteId] = useState('')
  const [filterPositionId, setFilterPositionId] = useState('')
  const [filterManagerId, setFilterManagerId] = useState('')
  const [search, setSearch] = useState('')
  const [viewMode, setViewMode] = useState<DirectoryView>(readStoredView)

  const effectiveSiteId = selectedSiteId || filterSiteId || ''

  useEffect(() => {
    if (selectedSiteId) setFilterSiteId('')
  }, [selectedSiteId])

  useEffect(() => {
    try {
      localStorage.setItem(VIEW_STORAGE_KEY, viewMode)
    } catch {
      /* ignore */
    }
  }, [viewMode])

  const departmentMap = useMemo(() => {
    const map: Record<string, string> = {}
    for (const d of departments) {
      if (d.id) map[d.id] = d.name ?? ''
    }
    return map
  }, [departments])

  const siteMap = useMemo(() => {
    const map: Record<string, string> = {}
    for (const s of sites) {
      map[s.id] = s.name
    }
    return map
  }, [sites])

  const positionsById = useMemo(() => {
    const map: Record<string, { name?: string | null }> = {}
    for (const p of jobPositions) {
      if (p.id) map[p.id] = p
    }
    return map
  }, [jobPositions])

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

  const filteredEmployees = useMemo(() => {
    const term = search.toLowerCase().trim()
    return allEmployees.filter((emp) => {
      if (filterStatus !== 'all' && emp.status !== filterStatus) return false
      if (filterDepartmentId && emp.department_id !== filterDepartmentId) return false
      if (effectiveSiteId && emp.site_id !== effectiveSiteId) return false
      if (filterPositionId && emp.job_position_id !== filterPositionId) return false
      if (filterManagerId && emp.manager_employee_id !== filterManagerId) return false
      if (term) {
        const placeName = jobPlaceName(emp.job_position_id, positionsById)
        const haystack = [emp.full_name, emp.preferred_name, emp.email, placeName, emp.employee_code]
          .filter(Boolean)
          .join(' ')
          .toLowerCase()
        if (!haystack.includes(term)) return false
      }
      return true
    })
  }, [
    allEmployees,
    filterStatus,
    filterDepartmentId,
    effectiveSiteId,
    filterPositionId,
    filterManagerId,
    search,
    positionsById,
  ])

  const managersWithReports = useMemo(() => {
    const ids = new Set(
      allEmployees.map((e) => e.manager_employee_id).filter(Boolean) as string[],
    )
    return allEmployees.filter((e) => e.id && ids.has(e.id))
  }, [allEmployees])

  const statusLabels: Record<string, string> = {
    all: t('employees.filter.all_statuses', 'Tots els estats'),
    active: t('employees.status.active', 'Actiu'),
    inactive: t('employees.status.inactive', 'Inactiu'),
    terminated: t('employees.status.terminated', 'Baixa definitiva'),
  }

  function openCreate() {
    setEditTarget(null)
    setFormOpen(true)
  }

  if (isLoading) {
    return (
      <div className="flex h-48 items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (error) {
    return (
      <div
        className="space-y-3 rounded-2xl border border-red-200 bg-red-50 p-6 text-center"
        data-testid="employees-load-error"
      >
        <p className="text-sm font-medium text-red-700">
          {t('employees.errors.load_failed', 'Error en carregar els empleats')}
        </p>
        <p className="text-xs text-red-600/80">
          {t(
            'employees.errors.load_failed_hint',
            'Comprova la connexió o els permisos del tenant i torna-ho a provar.',
          )}
        </p>
        <Button
          variant="outline"
          size="sm"
          onClick={() => window.location.reload()}
          data-testid="employees-reload"
        >
          {t('employees.errors.reload', 'Tornar a carregar')}
        </Button>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div
          className="inline-flex rounded-lg border border-border bg-muted/40 p-0.5"
          role="group"
          aria-label={t('employees.view.toggle_label', 'Vista del directori')}
        >
          <Button
            type="button"
            variant={viewMode === 'avatar' ? 'secondary' : 'ghost'}
            size="sm"
            className="h-8 gap-1.5"
            onClick={() => setViewMode('avatar')}
            data-testid="employees-view-avatar"
            aria-pressed={viewMode === 'avatar'}
          >
            <LayoutGrid className="h-4 w-4" />
            <span className="hidden sm:inline">{t('employees.view.avatar_cards', 'Targetes')}</span>
          </Button>
          <Button
            type="button"
            variant={viewMode === 'list' ? 'secondary' : 'ghost'}
            size="sm"
            className="h-8 gap-1.5"
            onClick={() => setViewMode('list')}
            data-testid="employees-view-list"
            aria-pressed={viewMode === 'list'}
          >
            <List className="h-4 w-4" />
            <span className="hidden sm:inline">{t('employees.view.list', 'Llista')}</span>
          </Button>
          <Button
            type="button"
            variant={viewMode === 'photo' ? 'secondary' : 'ghost'}
            size="sm"
            className="h-8 gap-1.5"
            onClick={() => setViewMode('photo')}
            data-testid="employees-view-photo"
            aria-pressed={viewMode === 'photo'}
          >
            <ImageIcon className="h-4 w-4" />
            <span className="hidden sm:inline">{t('employees.view.photo_cards', 'Foto')}</span>
          </Button>
        </div>

        <div className="flex flex-wrap items-center justify-end gap-2">
          <Button variant="outline" asChild className="gap-2">
            <Link to="/employees/organization">{t('employees.org.chart_link', 'Organigrama')}</Link>
          </Button>
          {canWrite ? (
            <>
              <Button variant="outline" asChild className="gap-2">
                <Link to="/employees/positions">{t('employees.positions.nav', 'Llocs de treball')}</Link>
              </Button>
              <Button
                variant="outline"
                onClick={() => setImportOpen(true)}
                className="gap-2"
                data-testid="employees-import-csv"
              >
                <Upload className="h-4 w-4" />
                {t('employees.import.button', 'Importar CSV')}
              </Button>
              <Button onClick={openCreate} className="gap-2" data-testid="employees-new">
                <Plus className="h-4 w-4" />
                {t('employees.new_employee', 'Nou empleat')}
              </Button>
            </>
          ) : null}
        </div>
      </div>

      <div className="space-y-3">
        {sitePillOptions.length > 0 ? (
          <FilterPillRow
            label={t('employees.filter.site_label', 'Local')}
            value={filterSiteId}
            onChange={setFilterSiteId}
            allLabel={t('employees.filter.all_sites', 'Tots els locals')}
            options={sitePillOptions}
            testId="employees-filter-sites"
          />
        ) : null}
        {departmentPillOptions.length > 0 ? (
          <FilterPillRow
            label={t('employees.filter.department_label', 'Departament')}
            value={filterDepartmentId}
            onChange={setFilterDepartmentId}
            allLabel={t('employees.filter.all_departments', 'Tots')}
            options={departmentPillOptions}
            testId="employees-filter-departments"
          />
        ) : null}

        <div className="flex flex-wrap items-center gap-2">
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('employees.filter.search_placeholder', 'Cerca per nom, email o document…')}
            className="w-56"
            data-testid="employees-search"
            aria-label={t('employees.filter.search_placeholder', 'Cerca per nom, email o document…')}
          />
          <select
            value={filterStatus}
            onChange={(e) => setFilterStatus(e.target.value as EmployeeStatus | 'all')}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            aria-label={t('employees.filter.status_label', 'Filtrar per estat')}
          >
            <option value="all">{statusLabels.all}</option>
            {EMPLOYEE_STATUSES.map((s) => (
              <option key={s} value={s}>
                {statusLabels[s]}
              </option>
            ))}
          </select>
          <select
            value={filterPositionId}
            onChange={(e) => setFilterPositionId(e.target.value)}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            aria-label={t('employees.filter.position_label', 'Filtrar per lloc de treball')}
          >
            <option value="">{t('employees.filter.all_positions', 'Tots els llocs de treball')}</option>
            {jobPositions.map((p) => (
              <option key={p.id!} value={p.id!}>
                {p.name}
              </option>
            ))}
          </select>
          <select
            value={filterManagerId}
            onChange={(e) => setFilterManagerId(e.target.value)}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
            aria-label={t('employees.filter.manager_label', 'Filtrar per manager')}
          >
            <option value="">{t('employees.filter.all_managers', 'Tots els managers')}</option>
            {managersWithReports.map((m) => (
              <option key={m.id!} value={m.id!}>
                {m.preferred_name || m.full_name}
              </option>
            ))}
          </select>
        </div>
      </div>

      {filteredEmployees.length === 0 ? (
        <div
          className="rounded-2xl border border-border bg-card p-12 text-center"
          data-testid="employees-empty"
        >
          <Users className="mx-auto mb-3 h-10 w-10 text-muted-foreground/40" aria-hidden />
          <p className="text-sm text-muted-foreground">
            {search ||
            filterStatus !== 'all' ||
            filterDepartmentId ||
            filterSiteId ||
            selectedSiteId ||
            filterPositionId ||
            filterManagerId
              ? t('employees.empty_filtered', 'Cap empleat coincideix amb els filtres actuals')
              : t('employees.empty', "Encara no hi ha empleats. Afegeix-ne un per començar.")}
          </p>
          {search ||
          filterStatus !== 'all' ||
          filterDepartmentId ||
          filterSiteId ||
          filterPositionId ||
          filterManagerId ? (
            <Button
              variant="outline"
              size="sm"
              className="mt-4"
              data-testid="employees-clear-filters"
              onClick={() => {
                setSearch('')
                setFilterStatus('all')
                setFilterDepartmentId('')
                setFilterSiteId('')
                setFilterPositionId('')
                setFilterManagerId('')
              }}
            >
              {t('employees.filter.clear', 'Netejar filtres')}
            </Button>
          ) : canWrite ? (
            <Button
              size="sm"
              className="mt-4 gap-2"
              data-testid="employees-empty-create"
              onClick={openCreate}
            >
              <Plus className="h-4 w-4" />
              {t('employees.new_employee', 'Nou empleat')}
            </Button>
          ) : null}
        </div>
      ) : viewMode === 'avatar' || viewMode === 'photo' ? (
        <div
          className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
          data-testid="employees-cards-grid"
          data-variant={viewMode}
        >
          {filteredEmployees.map((emp) => (
            <EmployeeCard
              key={emp.id}
              variant={viewMode as EmployeeCardVariant}
              employee={emp}
              departmentName={emp.department_id ? departmentMap[emp.department_id] : undefined}
              siteName={emp.site_id ? siteMap[emp.site_id] : undefined}
              positionName={jobPlaceName(emp.job_position_id, positionsById)}
              onEdit={(employee) => {
                setEditTarget(employee)
                setFormOpen(true)
              }}
              canWrite={canWrite}
              portalStatus={
                canManagePortal ? portalStatusForEmployee(statusByEmployeeId, emp.id) : null
              }
            />
          ))}
        </div>
      ) : (
        <div className="space-y-2" data-testid="employees-list">
          {filteredEmployees.map((emp) => (
            <EmployeeRow
              key={emp.id}
              employee={emp}
              departmentName={emp.department_id ? departmentMap[emp.department_id] : undefined}
              siteName={emp.site_id ? siteMap[emp.site_id] : undefined}
              positionName={jobPlaceName(emp.job_position_id, positionsById)}
              onEdit={(employee) => {
                setEditTarget(employee)
                setFormOpen(true)
              }}
              canWrite={canWrite}
            />
          ))}
        </div>
      )}

      <EmployeeForm
        open={formOpen}
        onClose={() => {
          setFormOpen(false)
          setEditTarget(null)
        }}
        editEmployee={editTarget}
      />

      <EmployeeImportCsvDialog open={importOpen} onOpenChange={setImportOpen} />
    </div>
  )
}
