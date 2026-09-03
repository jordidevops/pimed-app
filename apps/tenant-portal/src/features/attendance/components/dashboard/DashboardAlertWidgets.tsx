import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import type { TFunction } from 'i18next'
import { AlertTriangle, Clock, Stethoscope } from 'lucide-react'
import { useSiteAbsences, useAbsenceTypeConfigs } from '../../api/useAbsences'
import { useTenantEmployees } from '../../api/useShifts'
import { madridWorkDate } from '../../api/todayDashboardService'
import type { TodayDashboardRow } from '../../api/todayDashboardService'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { ANOMALY_UI } from '../../utils/anomalyUi'
import { recordsPageHref } from '../../utils/dateRangePresets'
import { employeeDashboardHref } from './DashboardLocationModal'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { absenceTypeLabel } from '../absences/absenceUiUtils'

function overlapsToday(startDate: string | null, endDate: string | null, today: string): boolean {
  if (!startDate) return false
  const end = endDate ?? startDate
  return startDate <= today && end >= today
}

interface DashboardIncidentsWidgetProps {
  rows: TodayDashboardRow[]
  t: TFunction
}

export function DashboardIncidentsWidget({ rows, t }: DashboardIncidentsWidgetProps) {
  const today = madridWorkDate(new Date().toISOString())
  const incidents = useMemo(
    () => rows.filter((r) => r.needs_review || (r.anomaly_codes?.length ?? 0) > 0),
    [rows],
  )

  return (
    <div className="rounded-xl border bg-card p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-semibold">
          <AlertTriangle className="h-4 w-4 text-orange-600" />
          {t('dashboard.incidents_widget_title', 'Incidències de fitxatge avui')}
        </p>
        <div className="flex items-center gap-2">
          <Badge variant={incidents.length > 0 ? 'destructive' : 'secondary'}>
            {incidents.length}
          </Badge>
          <Button type="button" variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
            <Link to={recordsPageHref(today, today)}>
              {t('dashboard.incidents_view_records', 'Veure fitxatges')}
            </Link>
          </Button>
        </div>
      </div>
      {incidents.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('dashboard.incidents_empty', 'Cap incidència avui')}
        </p>
      ) : (
        <ul className="space-y-2">
          {incidents.map((row) => (
            <li key={row.employee_id} className="rounded-lg border bg-muted/20 px-3 py-2">
              <Link
                to={employeeDashboardHref(row.employee_id)}
                className="text-sm font-medium text-primary hover:underline"
              >
                {row.employee_name}
              </Link>
              <div className="mt-1 flex flex-wrap gap-1">
                {row.needs_review && (
                  <Badge variant="outline" className="border-amber-300 text-amber-800 text-[10px]">
                    {t('timesheet.needs_review', 'Revisió')}
                  </Badge>
                )}
                {(row.anomaly_codes ?? []).map((code) => {
                  const meta = ANOMALY_UI[code]
                  return (
                    <Badge key={code} variant="outline" className="text-[10px]">
                      {meta ? t(meta.labelKey, code) : code}
                    </Badge>
                  )
                })}
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

interface DashboardPendingAbsencesWidgetProps {
  t: TFunction
  lang: string
}

export function DashboardPendingAbsencesWidget({ t, lang }: DashboardPendingAbsencesWidgetProps) {
  const today = madridWorkDate(new Date().toISOString())
  const year = new Date().getFullYear()
  const from = `${year}-01-01`
  const to = `${year + 1}-12-31`
  const formatDate = useFormatAttendanceDate()

  const { data: absences = [], isLoading } = useSiteAbsences(from, to)
  const { data: employees = [] } = useTenantEmployees()
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)

  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )

  const employeeMap = useMemo(
    () => Object.fromEntries(employees.map((e) => [e.id, e.full_name ?? e.id])),
    [employees],
  )

  const pendingToday = useMemo(
    () => absences.filter(
      (a) => a.status === 'requested' && overlapsToday(a.start_date, a.end_date, today),
    ),
    [absences, today],
  )

  const activeItToday = useMemo(
    () => absences.filter(
      (a) => a.status === 'active'
        && typeConfigMap[a.absence_type ?? '']?.is_it
        && overlapsToday(a.start_date, a.end_date, today),
    ),
    [absences, today, typeConfigMap],
  )

  const totalCount = pendingToday.length + activeItToday.length

  return (
    <div className="rounded-xl border bg-card p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between gap-2">
        <p className="flex items-center gap-2 text-sm font-semibold">
          <Clock className="h-4 w-4 text-amber-600" />
          {t('dashboard.absences_widget_title', 'Absències avui')}
        </p>
        <div className="flex items-center gap-2">
          {pendingToday.length > 0 && (
            <Badge variant="destructive">{pendingToday.length}</Badge>
          )}
          {activeItToday.length > 0 && (
            <Badge className="bg-blue-100 text-blue-800 hover:bg-blue-100">
              <Stethoscope className="mr-1 h-3 w-3" />
              {activeItToday.length}
            </Badge>
          )}
          {totalCount === 0 && <Badge variant="secondary">0</Badge>}
          <Button type="button" variant="link" size="sm" className="h-auto px-0 text-xs" asChild>
            <Link to="/attendance-mgmt/absences">
              {t('dashboard.absences_view_all', 'Veure absències')}
            </Link>
          </Button>
        </div>
      </div>
      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('dashboard.loading', 'Carregant…')}</p>
      ) : totalCount === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('dashboard.absences_empty_today', 'Cap absència rellevant avui')}
        </p>
      ) : (
        <ul className="space-y-2">
          {pendingToday.map((absence) => (
            <li key={absence.id} className="rounded-lg border bg-muted/20 px-3 py-2">
              <Link
                to={`/attendance-mgmt/absences?employeeId=${absence.employee_id}`}
                className="text-sm font-medium text-primary hover:underline"
              >
                {employeeMap[absence.employee_id ?? ''] ?? absence.employee_id}
              </Link>
              <p className="mt-0.5 text-xs text-muted-foreground">
                <Badge variant="outline" className="mr-1 border-amber-300 text-amber-800 text-[10px]">
                  {t('absences.status_requested', 'Pendent')}
                </Badge>
                {absenceTypeLabel(typeConfigMap[absence.absence_type ?? ''], absence.absence_type ?? '?', lang)}
                {absence.start_date && (
                  <span className="ml-1 tabular-nums">
                    · {formatDate(absence.start_date)}
                    {absence.end_date && absence.end_date !== absence.start_date && (
                      <> – {formatDate(absence.end_date)}</>
                    )}
                  </span>
                )}
              </p>
            </li>
          ))}
          {activeItToday.map((absence) => (
            <li key={`it-${absence.id}`} className="rounded-lg border border-blue-200 bg-blue-50/50 px-3 py-2">
              <Link
                to={`/attendance-mgmt/absences?employeeId=${absence.employee_id}`}
                className="text-sm font-medium text-primary hover:underline"
              >
                {employeeMap[absence.employee_id ?? ''] ?? absence.employee_id}
              </Link>
              <p className="mt-0.5 text-xs text-muted-foreground">
                <Badge variant="outline" className="mr-1 border-blue-300 text-blue-800 text-[10px]">
                  {t('absences.active_it_badge', 'IT activa')}
                </Badge>
                {absenceTypeLabel(typeConfigMap[absence.absence_type ?? ''], absence.absence_type ?? '?', lang)}
                {absence.start_date && (
                  <span className="ml-1 tabular-nums">
                    · {formatDate(absence.start_date)}
                    {absence.end_date && (
                      <> – {formatDate(absence.end_date)}</>
                    )}
                  </span>
                )}
              </p>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
