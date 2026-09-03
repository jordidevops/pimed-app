import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Users } from 'lucide-react'
import { useMemo } from 'react'
import { useEmployees } from '../api/useEmployees'
import { useEmployeeDirectReports } from '../api/useOrganization'
import { useJobPositions } from '../api/useJobPositions'
import { jobPlaceName } from '../utils/jobPlaceName'

export function EmployeeOrganizationSection({
  employeeId,
  managerEmployeeId,
  canWrite,
  onManagerChange,
}: {
  employeeId: string
  managerEmployeeId: string | null | undefined
  canWrite: boolean
  onManagerChange: (managerId: string | null) => void
}) {
  const { t } = useTranslation('employees')
  const { data: employees = [] } = useEmployees()
  const { data: reports = [], isLoading } = useEmployeeDirectReports(employeeId)
  const { data: jobPositions = [] } = useJobPositions(true)

  const positionsById = useMemo(() => {
    const map: Record<string, { name?: string | null }> = {}
    for (const p of jobPositions) {
      if (p.id) map[p.id] = p
    }
    return map
  }, [jobPositions])

  const managerOptions = employees.filter(
    (e) => e.id && e.id !== employeeId && e.status !== 'terminated',
  )
  const manager = employees.find((e) => e.id === managerEmployeeId)

  return (
    <div className="space-y-3 rounded-lg border border-border p-3">
      <div className="flex items-center gap-2">
        <Users className="h-4 w-4 text-muted-foreground" />
        <label className="text-sm font-medium">
          {t('employees.org.section_title', 'Organització')}
        </label>
      </div>

      <div className="space-y-1">
        <label className="text-xs text-muted-foreground">
          {t('employees.org.manager_label', 'Manager directe')}
        </label>
        {canWrite ? (
          <select
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            value={managerEmployeeId ?? ''}
            onChange={(e) => onManagerChange(e.target.value || null)}
          >
            <option value="">{t('employees.org.no_manager', 'Sense manager')}</option>
            {managerOptions.map((e) => {
              const place = jobPlaceName(e.job_position_id, positionsById)
              return (
                <option key={e.id!} value={e.id!}>
                  {(e.preferred_name || e.full_name) ?? e.id}
                  {place ? ` — ${place}` : ''}
                </option>
              )
            })}
          </select>
        ) : (
          <p className="text-sm">
            {manager ? (
              <Link to={`/employees/${manager.id}`} className="text-primary hover:underline">
                {manager.preferred_name || manager.full_name}
              </Link>
            ) : (
              <span className="text-muted-foreground">
                {t('employees.org.no_manager', 'Sense manager')}
              </span>
            )}
          </p>
        )}
      </div>

      <div className="space-y-1">
        <div className="flex items-center justify-between gap-2">
          <label className="text-xs text-muted-foreground">
            {t('employees.org.reports_label', 'Subordinats directes')}
          </label>
          <Link
            to={`/employees/organization?root=${employeeId}`}
            className="text-xs text-primary hover:underline"
          >
            {t('employees.org.view_team', 'Veure equip')}
          </Link>
        </div>
        {isLoading ? (
          <p className="text-xs text-muted-foreground">{t('employees.org.loading', 'Carregant…')}</p>
        ) : reports.length === 0 ? (
          <p className="text-xs text-muted-foreground">
            {t('employees.org.no_reports', 'Sense subordinats directes')}
          </p>
        ) : (
          <ul className="space-y-1">
            {reports.map((r) => (
              <li key={r.id}>
                <Link to={`/employees/${r.id}`} className="text-sm text-primary hover:underline">
                  {r.preferred_name || r.full_name}
                </Link>
                {r.job_position_name ? (
                  <span className="text-xs text-muted-foreground"> · {r.job_position_name}</span>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
