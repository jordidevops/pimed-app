import { useState, useMemo, useEffect } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Clock, ShieldOff, Stethoscope } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useTenant } from '@/contexts/TenantContext'
import { useSiteAbsences, useAbsenceTypeConfigs } from '../api/useAbsences'
import { useTenantEmployees } from '../api/useShifts'
import { EmployeeAbsenceRow } from '../components/absences/EmployeeAbsenceRow'
import { RegisterITDialog } from '../components/absences/RegisterITDialog'
import { madridWorkDate } from '../api/todayDashboardService'

function overlapsToday(startDate: string | null, endDate: string | null, today: string): boolean {
  if (!startDate) return false
  const end = endDate ?? startDate
  return startDate <= today && end >= today
}

export function AbsencesPage() {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const [searchParams] = useSearchParams()
  const { activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'

  const [filterEmployeeId, setFilterEmployeeId] = useState('')
  const [filterStatus, setFilterStatus] = useState('all')
  const [showRegisterIT, setShowRegisterIT] = useState(false)

  useEffect(() => {
    const employeeParam = searchParams.get('employeeId')
    if (employeeParam) setFilterEmployeeId(employeeParam)
  }, [searchParams])

  const year = new Date().getFullYear()
  const from = `${year - 1}-01-01`
  const to = `${year + 1}-12-31`

  const { data: employees = [] } = useTenantEmployees()
  const { data: allAbsences = [], isLoading } = useSiteAbsences(from, to)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)

  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )

  const itTypeConfigs = useMemo(() => typeConfigs.filter((c) => c.is_it), [typeConfigs])

  const employeeMap = useMemo(
    () => Object.fromEntries(employees.map((e) => [e.id, e.full_name ?? e.id])),
    [employees],
  )

  const filtered = useMemo(
    () =>
      allAbsences.filter(
        (a) =>
          (!filterEmployeeId || a.employee_id === filterEmployeeId) &&
          (filterStatus === 'all' || a.status === filterStatus),
      ),
    [allAbsences, filterEmployeeId, filterStatus],
  )

  const pendingCount = useMemo(
    () => allAbsences.filter((a) => a.status === 'requested').length,
    [allAbsences],
  )

  const today = madridWorkDate(new Date().toISOString())

  const activeTodayCount = useMemo(
    () => allAbsences.filter(
      (a) => a.status === 'active' && overlapsToday(a.start_date, a.end_date, today),
    ).length,
    [allAbsences, today],
  )

  const activeITCount = useMemo(
    () =>
      allAbsences.filter(
        (a) => a.status === 'active'
          && typeConfigMap[a.absence_type ?? '']?.is_it
          && overlapsToday(a.start_date, a.end_date, today),
      ).length,
    [allAbsences, typeConfigMap, today],
  )

  if (!isManager) {
    return (
      <div className="flex flex-col items-center gap-3 p-8 text-muted-foreground">
        <ShieldOff className="h-8 w-8" />
        <p className="text-sm">{t('shifts.no_permission', 'No tens permisos per accedir a aquesta pàgina')}</p>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-3xl p-4">
      <div className="mb-4 flex items-center justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-2xl font-semibold">{t('absences.title', 'Absències')}</h1>
            {pendingCount > 0 && (
              <Badge variant="destructive" title={t('absences.pending_count', "{{count}} pendents d'aprovació", { count: pendingCount })}>
                {pendingCount} {t('absences.badge_pending_short', 'pendents')}
              </Badge>
            )}
            {activeTodayCount > 0 && (
              <Badge className="bg-blue-100 text-blue-800 hover:bg-blue-100" title={t('absences.active_today_count', '{{count}} actives avui', { count: activeTodayCount })}>
                {activeTodayCount} {t('absences.badge_active_today_short', 'actives avui')}
              </Badge>
            )}
          </div>
            {activeITCount > 0 && (
            <p className="mt-1 text-sm text-blue-600">
              {t('absences.active_it_today_count', '{{count}} IT actives avui', { count: activeITCount })}
            </p>
          )}
        </div>
        {itTypeConfigs.length > 0 && (
          <Button size="sm" variant="outline" onClick={() => setShowRegisterIT(true)} className="gap-1.5">
            <Stethoscope className="h-3.5 w-3.5" />
            {t('absences.register_it_btn', 'Registrar IT')}
          </Button>
        )}
      </div>

      <div className="mb-4 flex flex-wrap gap-3">
        <select
          value={filterEmployeeId}
          onChange={(e) => setFilterEmployeeId(e.target.value)}
          className="rounded-md border bg-background px-3 py-1.5 text-sm"
        >
          <option value="">{t('absences.filter_all_employees', 'Tots els empleats')}</option>
          {employees.map((e) => (
            <option key={e.id} value={e.id ?? ''}>
              {e.full_name ?? e.id}
            </option>
          ))}
        </select>
        <select
          value={filterStatus}
          onChange={(e) => setFilterStatus(e.target.value)}
          className="rounded-md border bg-background px-3 py-1.5 text-sm"
        >
          <option value="all">{t('absences.filter_all_status', 'Tots els estats')}</option>
          <option value="requested">{t('absences.status.requested', 'Pendent')}</option>
          <option value="approved">{t('absences.status.approved', 'Aprovada')}</option>
          <option value="active">{t('absences.status.active', 'IT activa')}</option>
          <option value="closed">{t('absences.status.closed', 'IT tancada')}</option>
          <option value="rejected">{t('absences.status.rejected', 'Rebutjada')}</option>
          <option value="cancelled">{t('absences.status.cancelled', 'Cancel·lada')}</option>
          <option value="revoked">{t('absences.status.revoked', 'Revocada')}</option>
        </select>
      </div>

      {isLoading ? (
        <div className="py-12 text-center text-muted-foreground">
          <Clock className="mx-auto mb-2 h-6 w-6 animate-spin" />
          {t('absences.loading', 'Carregant absències...')}
        </div>
      ) : filtered.length === 0 ? (
        <div className="rounded-lg border py-12 text-center text-muted-foreground">
          {t('absences.empty', 'No hi ha absències registrades')}
        </div>
      ) : (
        <div className="flex flex-col gap-3">
          {filtered.map((a) => (
            <EmployeeAbsenceRow
              key={a.id}
              absence={a}
              employeeName={a.employee_id ? employeeMap[a.employee_id] : undefined}
              showEmployeeName
              typeCfg={typeConfigMap[a.absence_type ?? '']}
              lang={lang}
              isManager={isManager}
            />
          ))}
        </div>
      )}

      <RegisterITDialog
        open={showRegisterIT}
        onOpenChange={setShowRegisterIT}
        employees={employees}
        itTypeConfigs={itTypeConfigs}
        lang={lang}
      />
    </div>
  )
}
