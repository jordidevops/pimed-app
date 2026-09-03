import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Building2, CalendarDays, ExternalLink, MapPin } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { PlannerGridRow } from '../../api/schedulePlannerService'
import { ATTENDANCE_MGMT_BASE } from '../../attendanceMgmtRoutes'

interface ScheduleEmployeeLabelProps {
  row: PlannerGridRow
  fillCell?: boolean
}

export function ScheduleEmployeeLabel({ row, fillCell = false }: ScheduleEmployeeLabelProps) {
  const { t } = useTranslation('attendance')
  const { scope, label, employeeId } = row

  const editHref =
    scope === 'employee' && employeeId
      ? `/employees/${employeeId}?tab=work_calendar`
      : `${ATTENDANCE_MGMT_BASE}/calendar`

  const editTitle =
    scope === 'employee'
      ? t('schedule_planner.edit_employee_calendar', "Editar calendari de l'empleat")
      : t('schedule_planner.edit_site_calendar', 'Editar calendari del centre')

  if (scope === 'group') {
    return (
      <div className="flex min-h-8 items-center gap-2 px-1 text-xs font-semibold text-muted-foreground">
        {label}
      </div>
    )
  }

  return (
    <div
      className={cn(
        'group/label flex min-w-0 items-center gap-1.5 text-xs',
        scope !== 'employee' && 'font-medium text-muted-foreground',
        fillCell && 'relative min-h-9 w-full pr-7',
      )}
    >
      {scope === 'tenant' && <Building2 className="h-3.5 w-3.5 shrink-0" />}
      {scope === 'site' && <MapPin className="h-3.5 w-3.5 shrink-0" />}
      <span className="min-w-0 flex-1 truncate">{label}</span>
      <Link
        to={editHref}
        className={cn(
          'shrink-0 rounded p-0.5 text-muted-foreground transition-opacity hover:bg-accent hover:text-foreground focus:opacity-100',
          fillCell
            ? 'absolute right-0 top-0 opacity-0 group-hover/cell:opacity-100'
            : 'opacity-0 group-hover/label:opacity-100',
        )}
        title={editTitle}
        onClick={(e) => e.stopPropagation()}
      >
        {scope === 'employee' ? (
          <ExternalLink className="h-3.5 w-3.5" />
        ) : (
          <CalendarDays className="h-3.5 w-3.5" />
        )}
      </Link>
    </div>
  )
}
