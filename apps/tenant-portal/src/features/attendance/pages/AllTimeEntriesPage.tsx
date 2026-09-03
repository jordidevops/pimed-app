import { useState, useMemo, useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'
import { Clock, LayoutGrid, MapPin, ShieldOff, Table2 } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { useSiteEmployeesForSite, useTenantEmployees } from '../api/useShifts'
import { useRecordsListRows } from '../api/useRecordsList'
import { useAbsenceTypeConfigs } from '../api/useAbsences'
import { formatTimesheetMinutes } from '../api/timesheetService'
import { useAttendanceEffectiveSite } from '../hooks/useAttendanceEffectiveSite'
import { useAttendanceAllSitesFallbackToast } from '../hooks/useAttendanceAllSitesFallbackToast'
import { AttendanceLayerStatusBadge } from '../components/AttendanceLayerStatusBadge'
import { RegisterITDialog } from '../components/absences/RegisterITDialog'
import { RequestAbsenceDialog } from '../components/RequestAbsenceDialog'
import {
  AttendanceDayDetailDialog,
  type DayDetailSelection,
} from '../components/records/AttendanceDayDetailDialog'
import type { DayDetailPayrollActionHandlers } from '../components/records/DayDetailPayrollActionsSection'
import {
  PunchDetailsDialog,
  type PunchDetailsSelection,
} from '../components/records/PunchDetailsDialog'
import { RecordsListActions } from '../components/records/RecordsListActions'
import { MonthlyReportManagerButton } from '../components/records/MonthlyReportManagerDialog'
import { InspectionExportButton } from '../components/records/InspectionExportDialog'
import { PunchesExportButton } from '../components/records/PunchesExportButton'
import { PunchesListTable } from '../components/records/PunchesListTable'
import { LocationWorkSummaryExportButton } from '../components/records/LocationWorkSummaryExportButton'
import { LocationWorkSummaryTable } from '../components/records/LocationWorkSummaryTable'
import { PayrollExportButton } from '../components/records/PayrollExportDialog'
import { BulkApproveDraftBar } from '../components/records/BulkApproveDraftBar'
import { PayrollReviewDaysTable } from '../components/records/PayrollReviewDaysTable'
import { usePayrollReviewDays } from '../api/usePayrollReviewDays'
import { useSitePunches } from '../api/useSitePunches'
import { useLocationWorkSummary } from '../api/useLocationWorkSummary'
import { useFormatAttendanceDate } from '../hooks/useFormatAttendanceDate'
import { useLocations } from '@/features/locations/api/useLocations'
import { listAttendanceStations } from '@/features/attendance-stations/api/attendanceStationsService'
import { buildDateRangePresets, type DateRangePresetId } from '../utils/dateRangePresets'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { cn } from '@/lib/utils'

type RecordsViewMode = 'table' | 'cards' | 'punches' | 'location_summary'

function thisMonthRange() {
  const d = new Date()
  const y = d.getFullYear()
  const mo = d.getMonth()
  const from = `${y}-${String(mo + 1).padStart(2, '0')}-01`
  const last = new Date(y, mo + 1, 0)
  const to = `${y}-${String(mo + 1).padStart(2, '0')}-${String(last.getDate()).padStart(2, '0')}`
  return { from, to }
}

export function AllTimeEntriesPage() {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const [searchParams] = useSearchParams()
  const { activeRole, sites } = useTenant()
  const { effectiveSiteId, effectiveSite } = useAttendanceEffectiveSite()
  useAttendanceAllSitesFallbackToast()
  const { weekStartsOn } = useCalendarDisplaySettings()
  const formatDate = useFormatAttendanceDate()
  const isManager = activeRole === 'owner' || activeRole === 'manager'

  const datePresets = useMemo(() => buildDateRangePresets(new Date(), weekStartsOn), [weekStartsOn])

  const defaultRange = useMemo(() => thisMonthRange(), [])
  const [from, setFrom] = useState(() => searchParams.get('from') ?? defaultRange.from)
  const [to, setTo] = useState(() => searchParams.get('to') ?? defaultRange.to)
  const activePreset = useMemo(
    () => datePresets.find((p) => p.from === from && p.to === to)?.id ?? null,
    [datePresets, from, to],
  )
  const [filterEmployeeId, setFilterEmployeeId] = useState<string>(
    () => searchParams.get('employeeId') ?? 'all',
  )
  const [filterLocationId, setFilterLocationId] = useState<string>('all')
  const [filterDeviceId, setFilterDeviceId] = useState<string>('all')
  const [stations, setStations] = useState<{ id: string; name: string | null }[]>([])
  const [detailSelection, setDetailSelection] = useState<DayDetailSelection | null>(null)
  const [punchSelection, setPunchSelection] = useState<PunchDetailsSelection | null>(null)
  const [viewMode, setViewMode] = useState<RecordsViewMode>('table')
  const [absenceDialogDate, setAbsenceDialogDate] = useState<string | null>(null)
  const [itDialogDate, setItDialogDate] = useState<string | null>(null)

  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const { data: locations = [] } = useLocations()
  const itTypeConfigs = useMemo(() => typeConfigs.filter((c) => c.is_it), [typeConfigs])

  const siteIdParam = searchParams.get('siteId')
  const employeeIdParam = searchParams.get('employeeId')
  const { data: tenantEmployees = [] } = useTenantEmployees()
  const deepLinkSiteId = useMemo(() => {
    if (siteIdParam && sites.some((s) => s.id === siteIdParam)) return siteIdParam
    if (employeeIdParam) {
      return tenantEmployees.find((e) => e.id === employeeIdParam)?.site_id ?? null
    }
    return null
  }, [siteIdParam, employeeIdParam, tenantEmployees, sites])
  const resolvedSiteId = deepLinkSiteId ?? effectiveSiteId

  useEffect(() => {
    if (!resolvedSiteId) {
      setStations([])
      return
    }
    listAttendanceStations()
      .then((rows) =>
        setStations(
          rows
            .filter((s) => s.site_id === resolvedSiteId)
            .map((s) => ({ id: s.id, name: s.name })),
        ),
      )
      .catch(() => setStations([]))
  }, [resolvedSiteId])

  const singleEmployeeId = filterEmployeeId !== 'all' ? filterEmployeeId : null
  const autoOpenedDayRef = useRef<string | null>(null)

  useEffect(() => {
    const fromParam = searchParams.get('from')
    const toParam = searchParams.get('to')
    const employeeParam = searchParams.get('employeeId')
    if (fromParam) setFrom(fromParam)
    if (toParam) setTo(toParam)
    if (employeeParam) setFilterEmployeeId(employeeParam)
  }, [searchParams])

  const { data: employees = [] } = useSiteEmployeesForSite(resolvedSiteId)
  const { data: recordsRows = [], isLoading: recordsLoading } = useRecordsListRows(
    resolvedSiteId,
    from,
    to,
    singleEmployeeId ?? undefined,
  )
  const { data: payrollReview, isLoading: payrollReviewLoading } = usePayrollReviewDays(
    singleEmployeeId,
    from,
    to,
    !!singleEmployeeId,
  )

  const showLocationSummary = viewMode === 'location_summary'
  const showPunchesView =
    viewMode === 'punches' || filterLocationId !== 'all' || filterDeviceId !== 'all'
  const fetchSitePunchesEnabled = showPunchesView
  const { data: sitePunches = [], isLoading: punchesLoading } = useSitePunches(
    resolvedSiteId
      ? {
          siteId: resolvedSiteId,
          from,
          to,
          employeeId: singleEmployeeId ?? undefined,
          locationId: filterLocationId === 'all' ? undefined : filterLocationId,
          deviceId: filterDeviceId === 'all' ? undefined : filterDeviceId,
        }
      : null,
    fetchSitePunchesEnabled,
  )

  const { data: locationSummary, isLoading: locationSummaryLoading } = useLocationWorkSummary(
    resolvedSiteId && showLocationSummary
      ? {
          siteId: resolvedSiteId,
          from,
          to,
          employeeId: singleEmployeeId ?? undefined,
          locationId: filterLocationId === 'all' ? undefined : filterLocationId,
        }
      : null,
    showLocationSummary,
  )
  const locationSummaryRows = locationSummary?.rows ?? []

  const isLoading = singleEmployeeId
    ? showLocationSummary
      ? locationSummaryLoading
      : payrollReviewLoading
    : showLocationSummary
      ? locationSummaryLoading
      : fetchSitePunchesEnabled
        ? punchesLoading
        : recordsLoading

  const employeeMap = useMemo(
    () => Object.fromEntries(employees.map((e) => [e.id, e.full_name ?? e.id])),
    [employees],
  )

  function openPunchDetails(employeeId: string, workDate: string) {
    setPunchSelection({
      employeeId,
      workDate,
      employeeName: employeeMap[employeeId] ?? employeeId,
    })
  }

  function openDetail(
    employeeId: string,
    workDate: string,
    options?: { focusAdjust?: boolean },
  ) {
    setDetailSelection({
      employeeId,
      workDate,
      employeeName: employeeMap[employeeId] ?? employeeId,
      focusAdjust: options?.focusAdjust,
    })
  }

  useEffect(() => {
    if (!singleEmployeeId || from !== to || isLoading || showLocationSummary || viewMode === 'punches') return
    const key = `${singleEmployeeId}:${from}`
    if (autoOpenedDayRef.current === key) return
    autoOpenedDayRef.current = key
    openDetail(singleEmployeeId, from)
  }, [singleEmployeeId, from, to, isLoading, employeeMap])

  const selectedEmployeeName = singleEmployeeId
    ? employeeMap[singleEmployeeId] ?? singleEmployeeId
    : ''

  const payrollActionHandlers = useMemo((): DayDetailPayrollActionHandlers | undefined => {
    if (!singleEmployeeId) return undefined
    return {
      onRegisterAbsence: (workDate) => setAbsenceDialogDate(workDate),
      onRegisterIt: (workDate) => setItDialogDate(workDate),
      onOpenPunches: (workDate) => openPunchDetails(singleEmployeeId, workDate),
      onFocusAdjust: () => {
        setDetailSelection((prev) => (prev ? { ...prev, focusAdjust: true } : prev))
      },
    }
  }, [singleEmployeeId, employeeMap])

  if (!isManager) {
    return (
      <div className="flex flex-col items-center gap-3 p-8 text-muted-foreground">
        <ShieldOff className="h-8 w-8" />
        <p className="text-sm">{t('shifts.no_permission', 'No tens permisos per accedir a aquesta pàgina')}</p>
      </div>
    )
  }

  if (!resolvedSiteId) {
    return (
      <p className="text-center text-sm text-muted-foreground">
        {t('admin.no_site', 'Selecciona un centre per veure els fitxatges')}
      </p>
    )
  }

  return (
    <div className="mx-auto max-w-6xl space-y-6 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-center gap-2">
          <Clock className="h-5 w-5 text-muted-foreground" aria-hidden />
          <div>
            <h1 className="text-2xl font-semibold">{t('admin.title', "Fitxatges de l'equip")}</h1>
            <p className="text-sm text-muted-foreground">
              {singleEmployeeId
                ? t('admin.payroll_review_hint', 'Vista de revisió nòmina: tots els dies del període.')
                : t('day_detail.list_hint', 'Fes clic en una fila per veure raw vs processat')}
            </p>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <InspectionExportButton
            from={from}
            to={to}
            employeeId={filterEmployeeId === 'all' ? undefined : filterEmployeeId}
          />
          <PunchesExportButton
            from={from}
            to={to}
            employeeId={filterEmployeeId === 'all' ? undefined : filterEmployeeId}
            locationId={filterLocationId === 'all' ? undefined : filterLocationId}
            deviceId={filterDeviceId === 'all' ? undefined : filterDeviceId}
          />
          {showLocationSummary ? (
            <LocationWorkSummaryExportButton
              rows={locationSummaryRows}
              from={from}
              to={to}
              disabled={locationSummaryLoading}
            />
          ) : null}
          <PayrollExportButton
            from={from}
            to={to}
            employeeId={filterEmployeeId === 'all' ? undefined : filterEmployeeId}
          />
          <MonthlyReportManagerButton />
        </div>
      </div>

      <div className="space-y-3">
        <div className="flex flex-wrap gap-2">
          {([
            ['today', t('admin.preset_today', 'Avui')],
            ['this_week', t('admin.preset_this_week', 'Aquesta setmana')],
            ['this_month', t('admin.preset_this_month', 'Aquest mes')],
            ['prev_month', t('admin.preset_prev_month', 'Mes anterior')],
            ['this_year', t('admin.preset_this_year', 'Aquest any')],
          ] as [DateRangePresetId, string][]).map(([id, label]) => {
            const preset = datePresets.find((p) => p.id === id)
            if (!preset) return null
            return (
              <Badge
                key={id}
                variant={activePreset === id ? 'default' : 'outline'}
                className="cursor-pointer select-none"
                onClick={() => {
                  setFrom(preset.from)
                  setTo(preset.to)
                }}
              >
                {label}
              </Badge>
            )
          })}
        </div>

        <div className="flex flex-wrap items-end gap-4">
        <div className="space-y-1.5">
          <Label htmlFor="filter-from">{t('admin.filter_from', 'Des de')}</Label>
          <Input
            id="filter-from"
            type="date"
            value={from}
            onChange={(e) => setFrom(e.target.value)}
            className="w-[160px]"
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="filter-to">{t('admin.filter_to', 'Fins a')}</Label>
          <Input
            id="filter-to"
            type="date"
            value={to}
            min={from}
            onChange={(e) => setTo(e.target.value)}
            className="w-[160px]"
          />
        </div>
        <div className="min-w-[200px] space-y-1.5">
          <Label htmlFor="filter-employee">{t('admin.filter_all_employees', 'Empleat')}</Label>
          <select
            id="filter-employee"
            value={filterEmployeeId}
            onChange={(e) => setFilterEmployeeId(e.target.value)}
            className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="all">{t('admin.filter_all_employees', 'Tots els empleats')}</option>
            {employees.map((e) => (
              <option key={e.id} value={e.id ?? ''}>
                {e.full_name ?? e.id}
              </option>
            ))}
          </select>
        </div>
        <div className="min-w-[200px] space-y-1.5">
          <Label htmlFor="filter-location">{t('punch_export.filter_location', 'Ubicació')}</Label>
          <select
            id="filter-location"
            value={filterLocationId}
            onChange={(e) => setFilterLocationId(e.target.value)}
            className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="all">{t('punch_export.filter_all_locations', 'Totes les ubicacions')}</option>
            {locations.map((loc) => (
              <option key={loc.id} value={loc.id ?? ''}>
                {loc.name ?? loc.id}
              </option>
            ))}
          </select>
        </div>
        <div className="min-w-[200px] space-y-1.5">
          <Label htmlFor="filter-station">{t('punch_export.filter_station', 'Estació')}</Label>
          <select
            id="filter-station"
            value={filterDeviceId}
            onChange={(e) => setFilterDeviceId(e.target.value)}
            className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="all">{t('punch_export.filter_all_stations', 'Totes les estacions')}</option>
            {stations.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name ?? s.id}
              </option>
            ))}
          </select>
        </div>
        </div>
      </div>

      {!singleEmployeeId && <BulkApproveDraftBar summaries={recordsRows} />}

      <div className="flex justify-end gap-1">
        {!singleEmployeeId ? (
          <>
            <Button
              type="button"
              variant={viewMode === 'table' ? 'secondary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('table')}
            >
              <Table2 className="mr-1.5 h-4 w-4" />
              {t('admin.view_table', 'Taula')}
            </Button>
            <Button
              type="button"
              variant={viewMode === 'cards' ? 'secondary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('cards')}
            >
              <LayoutGrid className="mr-1.5 h-4 w-4" />
              {t('admin.view_cards', 'Targetes')}
            </Button>
          </>
        ) : null}
        <Button
          type="button"
          variant={viewMode === 'punches' ? 'secondary' : 'ghost'}
          size="sm"
          onClick={() => setViewMode('punches')}
        >
          <Clock className="mr-1.5 h-4 w-4" />
          {t('admin.view_punches', 'Fitxatges')}
        </Button>
        <Button
          type="button"
          variant={viewMode === 'location_summary' ? 'secondary' : 'ghost'}
          size="sm"
          onClick={() => setViewMode('location_summary')}
        >
          <MapPin className="mr-1.5 h-4 w-4" />
          {t('admin.view_location_summary', 'Hores per ubicació')}
        </Button>
      </div>

      {isLoading ? (
        <div className="py-12 text-center text-muted-foreground">
          <Clock className="mx-auto mb-2 h-6 w-6 animate-spin" />
          {t('shifts.loading', 'Carregant...')}
        </div>
      ) : showLocationSummary ? (
        <LocationWorkSummaryTable rows={locationSummaryRows} />
      ) : singleEmployeeId && payrollReview ? (
        payrollReview.days.length === 0 ? (
          <div className="rounded-lg border py-12 text-center text-muted-foreground">
            {t('admin.empty', 'Cap registre per al període seleccionat')}
          </div>
        ) : (
          <PayrollReviewDaysTable
            employeeId={singleEmployeeId}
            employeeName={selectedEmployeeName}
            days={payrollReview.days}
            onOpenDay={(workDate, options) => openDetail(singleEmployeeId, workDate, options)}
            onOpenPunches={(workDate) => openPunchDetails(singleEmployeeId, workDate)}
            onRegisterIt={(workDate) => setItDialogDate(workDate)}
            onRegisterAbsence={(workDate) => setAbsenceDialogDate(workDate)}
          />
        )
      ) : showPunchesView ? (
        <PunchesListTable punches={sitePunches} employeeNames={employeeMap} />
      ) : recordsRows.length === 0 ? (
        <div className="rounded-lg border py-12 text-center text-muted-foreground">
          {t('admin.empty', 'Cap registre per al període seleccionat')}
        </div>
      ) : viewMode === 'cards' ? (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {recordsRows.map((row) => {
            const balance = (row.worked_minutes ?? 0) - (row.expected_minutes ?? 0)
            const employeeName = employeeMap[row.employee_id] ?? row.employee_id
            const hasIncident = row.needs_review || (row.anomaly_codes?.length ?? 0) > 0
            const noPunches = (row.punch_count ?? 0) === 0

            return (
              <article
                key={`${row.employee_id}-${row.work_date}`}
                className={cn(
                  'flex flex-col rounded-xl border bg-card p-4 shadow-sm transition-colors hover:bg-muted/20',
                  row.needs_review && 'border-amber-200 bg-red-50/50',
                )}
              >
                <div className="mb-3 flex items-start justify-between gap-2">
                  <div>
                    <p className="font-semibold leading-tight">{employeeName}</p>
                    <p className="text-sm capitalize text-muted-foreground tabular-nums">
                      {formatDate(row.work_date)}
                    </p>
                  </div>
                  <RecordsListActions
                    punchCount={row.punch_count ?? 0}
                    onOpenPunches={() => openPunchDetails(row.employee_id, row.work_date)}
                    onOpenDay={() => openDetail(row.employee_id, row.work_date)}
                  />
                </div>

                <dl className="grid grid-cols-3 gap-2 text-sm">
                  <div>
                    <dt className="text-xs text-muted-foreground">{t('admin.col_worked', 'Treballat')}</dt>
                    <dd className="font-medium tabular-nums">
                      {formatTimesheetMinutes(row.worked_minutes)}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">{t('admin.col_expected', 'Previst')}</dt>
                    <dd className="tabular-nums text-muted-foreground">
                      {formatTimesheetMinutes(row.expected_minutes)}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-xs text-muted-foreground">{t('admin.col_balance', 'Balanç')}</dt>
                    <dd
                      className={cn(
                        'tabular-nums font-medium',
                        balance < 0
                          ? 'text-red-600'
                          : balance > 0
                            ? 'text-green-600'
                            : 'text-muted-foreground',
                      )}
                    >
                      {balance !== 0
                        ? (balance > 0 ? '+' : '') + formatTimesheetMinutes(balance)
                        : '—'}
                    </dd>
                  </div>
                </dl>

                <div className="mt-3 flex flex-wrap gap-1">
                  <AttendanceLayerStatusBadge
                    status={row.status ?? 'draft'}
                    layer="summary"
                    t={t}
                  />
                  {row.is_live_punch && (
                    <Badge variant="outline" className="border-sky-300 text-sky-800 text-xs">
                      {t('punch_details.live_badge', 'En viu')}
                    </Badge>
                  )}
                  {row.needs_review && (
                    <Badge variant="outline" className="border-amber-300 text-amber-800 text-xs">
                      {t('timesheet.needs_review', 'Revisió pendent')}
                    </Badge>
                  )}
                  {!hasIncident && noPunches && (
                    <Badge variant="outline" className="text-xs text-muted-foreground">
                      {t('day_detail.no_punches_short', 'Sense fitxatges')}
                    </Badge>
                  )}
                </div>
              </article>
            )
          })}
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t('admin.col_employee', 'Empleat/da')}</TableHead>
                <TableHead>{t('admin.col_date', 'Data')}</TableHead>
                <TableHead className="text-right">{t('admin.col_worked', 'Treballat')}</TableHead>
                <TableHead className="text-right">{t('admin.col_expected', 'Previst')}</TableHead>
                <TableHead className="text-right">{t('admin.col_balance', 'Balanç')}</TableHead>
                <TableHead className="text-center">{t('status_layers.col_summary', 'Dia nòmina')}</TableHead>
                <TableHead className="text-right">{t('payroll_review.col_actions', 'Accions')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {recordsRows.map((row) => {
                const balance = (row.worked_minutes ?? 0) - (row.expected_minutes ?? 0)
                const employeeName = employeeMap[row.employee_id] ?? row.employee_id
                const hasIncident =
                  row.needs_review || (row.anomaly_codes?.length ?? 0) > 0
                const noPunches = (row.punch_count ?? 0) === 0

                return (
                  <TableRow
                    key={`${row.employee_id}-${row.work_date}`}
                    className={cn(
                      'cursor-pointer transition-colors hover:bg-muted/40',
                      row.needs_review && 'bg-red-50/80',
                    )}
                    onClick={() => openDetail(row.employee_id, row.work_date)}
                  >
                    <TableCell className="font-medium">{employeeName}</TableCell>
                    <TableCell className="text-muted-foreground tabular-nums">{formatDate(row.work_date)}</TableCell>
                    <TableCell className="text-right tabular-nums">
                      {formatTimesheetMinutes(row.worked_minutes)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums text-muted-foreground">
                      {formatTimesheetMinutes(row.expected_minutes)}
                    </TableCell>
                    <TableCell
                      className={cn(
                        'text-right tabular-nums font-medium',
                        balance < 0
                          ? 'text-red-600'
                          : balance > 0
                            ? 'text-green-600'
                            : 'text-muted-foreground',
                      )}
                    >
                      {balance !== 0
                        ? (balance > 0 ? '+' : '') + formatTimesheetMinutes(balance)
                        : '—'}
                    </TableCell>
                    <TableCell className="text-center">
                      <div className="flex flex-wrap items-center justify-center gap-1">
                        <AttendanceLayerStatusBadge
                          status={row.status ?? 'draft'}
                          layer="summary"
                          t={t}
                        />
                        {row.is_live_punch && (
                          <Badge variant="outline" className="border-sky-300 text-sky-800 text-xs">
                            {t('punch_details.live_badge', 'En viu')}
                          </Badge>
                        )}
                        {row.needs_review && (
                          <Badge variant="outline" className="border-amber-300 text-amber-800">
                            {t('timesheet.needs_review', 'Revisió pendent')}
                          </Badge>
                        )}
                        {!hasIncident && noPunches && (
                          <Badge variant="outline" className="text-muted-foreground">
                            {t('day_detail.no_punches_short', 'Sense fitxatges')}
                          </Badge>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="text-right">
                      <RecordsListActions
                        punchCount={row.punch_count ?? 0}
                        onOpenPunches={() => openPunchDetails(row.employee_id, row.work_date)}
                        onOpenDay={() => openDetail(row.employee_id, row.work_date)}
                      />
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        </div>
      )}

      <AttendanceDayDetailDialog
        selection={detailSelection}
        open={detailSelection != null}
        onOpenChange={(open) => {
          if (!open) setDetailSelection(null)
        }}
        payrollActionHandlers={payrollActionHandlers}
      />

      <PunchDetailsDialog
        selection={punchSelection}
        open={punchSelection != null}
        onOpenChange={(open) => {
          if (!open) setPunchSelection(null)
        }}
      />

      {singleEmployeeId && itDialogDate ? (
        <RegisterITDialog
          key={itDialogDate}
          open
          onOpenChange={(open) => {
            if (!open) setItDialogDate(null)
          }}
          employeeId={singleEmployeeId}
          employeeName={selectedEmployeeName}
          itTypeConfigs={itTypeConfigs}
          lang={lang}
          initialStartDate={itDialogDate}
        />
      ) : null}

      {singleEmployeeId && absenceDialogDate ? (
        <RequestAbsenceDialog
          key={absenceDialogDate}
          employeeId={singleEmployeeId}
          managerMode
          suggestUnjustified
          initialStartDate={absenceDialogDate}
          initialEndDate={absenceDialogDate}
          onClose={() => setAbsenceDialogDate(null)}
        />
      ) : null}
    </div>
  )
}
