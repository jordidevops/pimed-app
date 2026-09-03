import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { ChevronLeft, ChevronRight, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { useEmployeeTimesheet } from '../api/useEmployeeTimesheet'
import { useEmployeeTimesheetPunches } from '../api/useEmployeeTimesheetPunches'
import { useAbsenceTypeConfigs } from '../api/useAbsences'
import type { AbsenceTypeConfig } from '../api/shiftsService'
import {
  formatTimesheetMinutes,
  employeeAbsencesUrl,
  payrollRecordsDayReviewUrl,
  type TimesheetDayRow,
} from '../api/timesheetService'
import {
  emptyTimesheetDay,
  isTimesheetReviewPendingDay,
  resolveTimesheetDayVisualKind,
  TIMESHEET_DAY_CARD_CLASS,
  timesheetDayKindLabelKey,
  timesheetDayTypeLabelKey,
  type TimesheetDayVisualKind,
} from '../api/timesheetDayUtils'
import { isOvertimeAttentionDay, timesheetOvertimeStats } from '../utils/overtimeReviewUtils'
import {
  AttendanceLayerStatusBadge,
  TimesheetDayLayerBadges,
} from './AttendanceLayerStatusBadge'
import { AttendanceLegalCountersPanel } from './records/AttendanceLegalCountersPanel'
import { CompensationLedgerPanel } from './records/CompensationLedgerPanel'
import { MonthlyAttendanceReportPanel } from './records/MonthlyAttendanceReportPanel'
import { EmployeeAbsencesPanel } from './absences/EmployeeAbsencesPanel'
import { AbsenceItBadge } from './absences/AbsenceItBadge'
import { TimesheetManagerActionBar } from './TimesheetManagerActionBar'
import { AttendanceProtocolPublishButton } from './AttendanceProtocolPublishButton'
import { SchedulePeriodPicker } from './schedule-planner/SchedulePeriodPicker'
import {
  getPlannerPeriodBounds,
  toLocalIsoDate,
} from '../api/schedulePlannerService'
import { useFormatAttendanceDate } from '../hooks/useFormatAttendanceDate'
import {
  AttendanceDayDetailDialog,
  type DayDetailSelection,
} from './records/AttendanceDayDetailDialog'
import { PunchDetailsDialog, type PunchDetailsSelection } from './records/PunchDetailsDialog'
import { RegisterITDialog } from './absences/RegisterITDialog'
import { RequestAbsenceDialog } from './RequestAbsenceDialog'
import type { DayDetailPayrollActionHandlers } from './records/DayDetailPayrollActionsSection'
import { TimesheetDayPunchesCell } from './TimesheetDayPunchesCell'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { parsePunchDiscrepancyToleranceMinutes } from '../api/punchDiscrepancySettings'
import type { EmployeeTimesheetPunchContext } from '../api/useEmployeeTimesheetPunches'
import { useTenant } from '@/contexts/TenantContext'

type TimesheetViewMode = 'week' | 'month' | 'list'
type DaySortOrder = 'desc' | 'asc'

interface EmployeeTimesheetTabProps {
  employeeId: string
  siteId?: string
  employeeName?: string
  employeeEmail?: string | null
  employeePhone?: string | null
  workProfile?: string | null
  canManage?: boolean
}

function todayIso(): string {
  return toLocalIsoDate(new Date())
}

export function EmployeeTimesheetTab({
  employeeId,
  siteId,
  employeeName,
  employeeEmail,
  employeePhone,
  workProfile,
  canManage = false,
}: EmployeeTimesheetTabProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { weekStartsOn } = useCalendarDisplaySettings()
  const formatDate = useFormatAttendanceDate()
  const [viewMode, setViewMode] = useState<TimesheetViewMode>('week')
  const [daySortOrder, setDaySortOrder] = useState<DaySortOrder>('desc')
  const [anchor, setAnchor] = useState(() => new Date())
  const [detailSelection, setDetailSelection] = useState<DayDetailSelection | null>(null)
  const [punchSelection, setPunchSelection] = useState<PunchDetailsSelection | null>(null)
  const [absenceDialogDate, setAbsenceDialogDate] = useState<string | null>(null)
  const [itDialogDate, setItDialogDate] = useState<string | null>(null)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )
  const itTypeConfigs = useMemo(() => typeConfigs.filter((c) => c.is_it), [typeConfigs])
  const managerYear = anchor.getFullYear()
  const managerMonth = anchor.getMonth() + 1

  const plannerMode = viewMode === 'list' ? 'month' : viewMode
  const { from, to, dates } = useMemo(
    () => getPlannerPeriodBounds(anchor, plannerMode, weekStartsOn),
    [anchor, plannerMode, weekStartsOn],
  )

  const { data: days = [], isLoading, error, refetch, isRefetching } = useEmployeeTimesheet(
    siteId ?? null,
    employeeId,
    from,
    to,
  )

  const { activeTenant } = useTenant()
  const showListTable = viewMode === 'week' || viewMode === 'list'
  const { data: effectiveSettings = {} } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null, siteId: siteId ?? null },
    { enabled: !!activeTenant?.id && !!siteId && showListTable },
  )
  const punchDiscrepancyToleranceMin = parsePunchDiscrepancyToleranceMinutes(effectiveSettings)
  const { punchContext } = useEmployeeTimesheetPunches(
    employeeId,
    from,
    to,
    showListTable,
  )

  const dayMap = useMemo(
    () => new Map(days.map((d) => [d.work_date, d])),
    [days],
  )

  const sortedDays = useMemo(() => {
    const list = [...days].sort((a, b) => a.work_date.localeCompare(b.work_date))
    if (daySortOrder === 'desc') list.reverse()
    return list
  }, [days, daySortOrder])

  const payrollActionHandlers = useMemo((): DayDetailPayrollActionHandlers | undefined => {
    if (!canManage) return undefined
    return {
      onRegisterAbsence: (workDate) => setAbsenceDialogDate(workDate),
      onRegisterIt: (workDate) => setItDialogDate(workDate),
      onOpenPunches: (workDate) => {
        if (!employeeName) return
        setPunchSelection({ employeeId, workDate, employeeName })
      },
      onFocusAdjust: () => {
        setDetailSelection((prev) => (prev ? { ...prev, focusAdjust: true } : prev))
      },
    }
  }, [canManage, employeeId, employeeName])

  function openDayDetail(workDate: string, options?: { focusAdjust?: boolean }) {
    if (!employeeName) return
    setDetailSelection({
      employeeId,
      workDate,
      employeeName,
      focusAdjust: options?.focusAdjust,
    })
  }

  const periodLabel = useMemo(() => {
    if (viewMode === 'week') {
      const start = new Date(`${from}T12:00:00`)
      const end = new Date(`${to}T12:00:00`)
      return `${start.toLocaleDateString('ca-ES', { day: 'numeric', month: 'short' })} – ${end.toLocaleDateString('ca-ES', { day: 'numeric', month: 'short', year: 'numeric' })}`
    }
    return anchor.toLocaleDateString('ca-ES', { month: 'long', year: 'numeric' })
  }, [viewMode, from, to, anchor])

  const totals = useMemo(() => {
    let worked = 0
    let expected = 0
    let hasExpected = false
    for (const d of days) {
      worked += d.worked_minutes
      if (d.expected_minutes != null) {
        expected += d.expected_minutes
        hasExpected = true
      }
    }
    const overtime = timesheetOvertimeStats(days)
    return {
      worked,
      expected: hasExpected ? expected : null,
      overtimeMinutes: overtime.totalMinutes,
      overtimeDays: overtime.attentionCount,
    }
  }, [days])

  function shiftPeriod(delta: number) {
    setAnchor((prev) => {
      const d = new Date(prev)
      if (viewMode === 'week') d.setDate(d.getDate() + delta * 7)
      else d.setMonth(d.getMonth() + delta)
      return d
    })
  }

  if (!siteId) {
    return (
      <p className="py-4 text-sm text-muted-foreground">
        {t('admin.no_site', 'Selecciona un local per veure el full horari')}
      </p>
    )
  }

  const dowAbbr = t('labor_cal.dow_abbr', { returnObjects: true }) as string[]
  const dowLabels = Array.isArray(dowAbbr) ? dowAbbr : []
  const months = t('labor_cal.months', { returnObjects: true }) as string[]
  const monthList = Array.isArray(months) ? months : []
  const pickerViewMode = viewMode === 'week' ? 'week' : 'month'

  return (
    <div className="space-y-4">
      {canManage ? (
        <TimesheetManagerActionBar
          employeeId={employeeId}
          employeeName={employeeName}
          siteId={siteId}
          year={managerYear}
          month={managerMonth}
        />
      ) : null}

      {canManage ? (
        <EmployeeAbsencesPanel
          employeeId={employeeId}
          employeeName={employeeName}
          canManage={canManage}
          hideQuickActions
        />
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <div className="inline-flex overflow-hidden rounded-lg border">
          {(['week', 'month', 'list'] as const).map((mode) => (
            <button
              key={mode}
              type="button"
              onClick={() => setViewMode(mode)}
              className={cn(
                'px-3 py-1.5 text-xs font-medium transition-colors',
                viewMode === mode
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-background text-muted-foreground hover:bg-accent',
              )}
            >
              {mode === 'week'
                ? t('timesheet.view_week', 'Setmana')
                : mode === 'month'
                  ? t('timesheet.view_month', 'Mes')
                  : t('timesheet.view_list', 'Llista')}
            </button>
          ))}
        </div>

        <div className="inline-flex items-center rounded-lg border bg-background">
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 rounded-r-none"
            onClick={() => shiftPeriod(-1)}
          >
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <div className="border-x px-1">
            <SchedulePeriodPicker
              anchor={anchor}
              viewMode={pickerViewMode}
              months={monthList}
              periodLabel={periodLabel}
              isRefreshing={isLoading}
              onApply={setAnchor}
            />
          </div>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 rounded-l-none"
            onClick={() => shiftPeriod(1)}
          >
            <ChevronRight className="h-4 w-4" />
          </Button>
        </div>

        <Button type="button" variant="outline" size="sm" className="h-8" onClick={() => setAnchor(new Date())}>
          {t('schedule_planner.today', 'Avui')}
        </Button>

        {(viewMode === 'month' || viewMode === 'list') && (
          <div className="inline-flex overflow-hidden rounded-lg border">
            {(['desc', 'asc'] as const).map((order) => (
              <button
                key={order}
                type="button"
                onClick={() => setDaySortOrder(order)}
                className={cn(
                  'px-3 py-1.5 text-xs font-medium transition-colors',
                  daySortOrder === order
                    ? 'bg-primary text-primary-foreground'
                    : 'bg-background text-muted-foreground hover:bg-accent',
                )}
              >
                {order === 'desc'
                  ? t('timesheet.sort_newest', 'Més recents primer')
                  : t('timesheet.sort_oldest', 'Més antics primer')}
              </button>
            ))}
          </div>
        )}

        {canManage && employeeName && (
          <AttendanceProtocolPublishButton
            employeeId={employeeId}
            employeeName={employeeName}
            employeeEmail={employeeEmail}
            workProfile={workProfile}
          />
        )}
      </div>

      <div className="flex flex-wrap gap-4 rounded-lg border bg-muted/30 px-4 py-3 text-sm">
        <div>
          <span className="text-muted-foreground">{t('admin.col_worked', 'Treballat')}: </span>
          <span className="font-semibold tabular-nums">{formatTimesheetMinutes(totals.worked)}</span>
        </div>
        {totals.expected != null && (
          <div>
            <span className="text-muted-foreground">{t('admin.col_expected', 'Previst')}: </span>
            <span className="font-semibold tabular-nums">{formatTimesheetMinutes(totals.expected)}</span>
          </div>
        )}
        {totals.expected != null && (
          <div>
            <span className="text-muted-foreground">{t('admin.col_balance', 'Balanç')}: </span>
            <span
              className={cn(
                'font-semibold tabular-nums',
                totals.worked - totals.expected >= 0 ? 'text-green-700' : 'text-red-600',
              )}
            >
              {formatTimesheetMinutes(totals.worked - totals.expected)}
            </span>
          </div>
        )}
        {totals.overtimeMinutes > 0 && (
          <div>
            <span className="text-muted-foreground">
              {t('payroll_review.col_overtime', 'Extra')}:{' '}
            </span>
            <span className="font-semibold tabular-nums text-violet-800">
              {formatTimesheetMinutes(totals.overtimeMinutes)}
            </span>
            {totals.overtimeDays > 0 && (
              <span className="ml-1 text-xs text-violet-700">
                ({totals.overtimeDays} {t('timesheet.overtime_days_short', 'dies')})
              </span>
            )}
          </div>
        )}
      </div>

      <TimesheetCalendarLegend t={t} />

      {error ? (
        <div className="rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-3 text-sm text-destructive">
          <p>{t('timesheet.load_error', 'No s\'han pogut carregar les dades del full horari.')}</p>
          <p className="mt-1 text-xs opacity-90">{error.message}</p>
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="mt-2"
            disabled={isRefetching}
            onClick={() => void refetch()}
          >
            {isRefetching ? (
              <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
            ) : null}
            {t('timesheet.retry', 'Torna-ho a provar')}
          </Button>
        </div>
      ) : isLoading ? (
        <div className="flex h-40 items-center justify-center text-sm text-muted-foreground">
          {t('admin.loading', 'Carregant...')}
        </div>
      ) : viewMode === 'week' ? (
        <TimesheetWeekGrid
          dates={dates}
          dayMap={dayMap}
          dowLabels={dowLabels}
          typeConfigMap={typeConfigMap}
          employeeId={employeeId}
          siteId={siteId}
          canManage={canManage}
          formatDate={formatDate}
          onDayClick={canManage ? openDayDetail : undefined}
          t={t}
        />
      ) : viewMode === 'month' ? null : (
        <TimesheetListTable
          days={sortedDays}
          typeConfigMap={typeConfigMap}
          employeeId={employeeId}
          siteId={siteId}
          canManage={canManage}
          formatDate={formatDate}
          onDayClick={canManage ? openDayDetail : undefined}
          punchContext={punchContext}
          punchDiscrepancyToleranceMin={punchDiscrepancyToleranceMin}
          t={t}
        />
      )}

      {viewMode === 'month' && (
        <>
          <AttendanceLegalCountersPanel employeeId={employeeId} />
          <CompensationLedgerPanel employeeId={employeeId} canManage={canManage} />
          <MonthlyAttendanceReportPanel
            employeeId={employeeId}
            employeeName={employeeName}
            employeeEmail={employeeEmail}
            employeePhone={employeePhone}
            siteId={siteId}
            year={anchor.getFullYear()}
            month={anchor.getMonth() + 1}
            variant="manager"
            daySortOrder={daySortOrder}
          />
        </>
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

      {canManage && absenceDialogDate ? (
        <RequestAbsenceDialog
          key={absenceDialogDate}
          employeeId={employeeId}
          managerMode
          suggestUnjustified
          initialStartDate={absenceDialogDate}
          initialEndDate={absenceDialogDate}
          onClose={() => setAbsenceDialogDate(null)}
        />
      ) : null}

      {canManage && itDialogDate ? (
        <RegisterITDialog
          key={itDialogDate}
          open
          onOpenChange={(open) => {
            if (!open) setItDialogDate(null)
          }}
          employeeId={employeeId}
          employeeName={employeeName}
          itTypeConfigs={itTypeConfigs}
          lang={lang}
          initialStartDate={itDialogDate}
        />
      ) : null}
    </div>
  )
}

function TimesheetCalendarLegend({
  t,
}: {
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const kinds: TimesheetDayVisualKind[] = [
    'worked',
    'absence',
    'it',
    'holiday',
    'missing_punch',
    'pending',
    'blocked',
    'non_working',
  ]

  return (
    <div className="flex flex-wrap gap-2">
      {kinds.map((kind) => (
        <span
          key={kind}
          className={cn(
            'inline-flex items-center rounded-md border px-2 py-0.5 text-[10px] font-medium',
            TIMESHEET_DAY_CARD_CLASS[kind],
          )}
        >
          {t(timesheetDayKindLabelKey(kind), kind)}
        </span>
      ))}
    </div>
  )
}

function TimesheetDaySubtitle({
  day,
  typeConfigMap,
  employeeId,
  canManage,
  t,
}: {
  day: TimesheetDayRow
  typeConfigMap: Record<string, AbsenceTypeConfig>
  employeeId: string
  canManage: boolean
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const kind = resolveTimesheetDayVisualKind(day)
  const absenceHref = canManage ? employeeAbsencesUrl(employeeId) : undefined

  if (day.is_it && day.absence_id) {
    return (
      <AbsenceItBadge
        isIt
        absenceType={day.absence_type}
        typeConfigMap={typeConfigMap}
        size="xs"
        className="mt-1"
        href={absenceHref}
      />
    )
  }

  if (day.absence_id) {
    return (
      <AbsenceItBadge
        isIt={false}
        absenceType={day.absence_type}
        typeConfigMap={typeConfigMap}
        size="xs"
        className="mt-1"
        href={absenceHref}
      />
    )
  }

  if (day.holiday_name) {
    return (
      <p className="mt-1 line-clamp-2 text-[9px] text-muted-foreground" title={day.holiday_name}>
        {day.holiday_name}
      </p>
    )
  }

  if (kind === 'missing_punch') {
    return (
      <p className="mt-1 text-[9px] font-medium text-orange-800">
        {t('timesheet.missing_punch', 'Falta registre')}
      </p>
    )
  }

  if (kind === 'pending' && day.expected_minutes) {
    return (
      <p className="mt-1 text-[9px] text-amber-800">
        {t('timesheet.expected_short', 'Prev. {{time}}', {
          time: formatTimesheetMinutes(day.expected_minutes),
        })}
      </p>
    )
  }

  if (isOvertimeAttentionDay(day)) {
    return (
      <p className="mt-1 text-[9px] font-medium text-violet-800">
        {t('timesheet.overtime_short', 'Extra {{time}}', {
          time: formatTimesheetMinutes(day.overtime_minutes ?? 0),
        })}
      </p>
    )
  }

  if (day.day_type && day.day_type !== 'working') {
    return (
      <p className="mt-1 text-[9px] text-muted-foreground">
        {t(timesheetDayTypeLabelKey(day.day_type), day.day_type)}
      </p>
    )
  }

  return null
}

function TimesheetReviewPendingBadge({
  day,
  employeeId,
  siteId,
  canManage,
  t,
  className,
}: {
  day: TimesheetDayRow
  employeeId: string
  siteId?: string
  canManage: boolean
  t: (key: string, fallback?: string) => string
  className?: string
}) {
  if (!isTimesheetReviewPendingDay(day)) return null

  const label = t('timesheet.needs_review', 'Revisió pendent')
  const badge = (
    <Badge
      variant="outline"
      className={cn('border-amber-300 bg-amber-100 text-amber-800 text-xs', className)}
    >
      {label}
    </Badge>
  )

  if (!canManage) return badge

  return (
    <Link
      to={payrollRecordsDayReviewUrl(employeeId, day.work_date, siteId)}
      className="inline-flex"
    >
      {badge}
    </Link>
  )
}

function TimesheetDayCard({
  day,
  compact = false,
  typeConfigMap,
  employeeId,
  siteId,
  canManage,
  formatDate,
  onDayClick,
  t,
}: {
  day: TimesheetDayRow
  compact?: boolean
  typeConfigMap: Record<string, AbsenceTypeConfig>
  employeeId: string
  siteId?: string
  canManage: boolean
  formatDate?: (iso: string) => string
  onDayClick?: (workDate: string) => void
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const kind = resolveTimesheetDayVisualKind(day)
  const hasActivity = day.punch_count > 0 || day.worked_minutes > 0
  const isToday = day.work_date === todayIso()
  const overtimeAttention = isOvertimeAttentionDay(day)
  const reviewPending = isTimesheetReviewPendingDay(day)
  const balance =
    day.expected_minutes != null ? day.worked_minutes - day.expected_minutes : null
  const clickable = Boolean(onDayClick)

  const inner = (
    <>
      <div className="flex items-center justify-between gap-1">
        <span className={cn('text-xs font-medium tabular-nums', isToday && 'text-primary')}>
          {compact ? day.work_date.slice(8, 10) : (formatDate?.(day.work_date) ?? day.work_date)}
        </span>
        {reviewPending ? (
          <TimesheetReviewPendingBadge
            day={day}
            employeeId={employeeId}
            siteId={siteId}
            canManage={canManage}
            t={t}
          />
        ) : day.entry_status || day.summary_status ? (
          <TimesheetDayLayerBadges
            entryStatus={day.entry_status}
            summaryStatus={day.summary_status}
            t={t}
            size="xs"
            layout="col"
          />
        ) : null}
      </div>
      <div className={cn('mt-1 font-semibold tabular-nums', compact ? 'text-sm' : 'text-base')}>
        {hasActivity ? formatTimesheetMinutes(day.worked_minutes) : '—'}
      </div>
      <TimesheetDaySubtitle
        day={day}
        typeConfigMap={typeConfigMap}
        employeeId={employeeId}
        canManage={canManage}
        t={t}
      />
      {day.punch_count > 0 && (
        <div className="mt-0.5 text-[10px] text-muted-foreground tabular-nums">
          {t('schedule_planner.punch_count', '{{count}} fitx.', { count: day.punch_count })}
        </div>
      )}
      {!compact && balance != null && hasActivity && (
        <div
          className={cn(
            'mt-auto pt-1 text-[10px] font-medium tabular-nums',
            balance >= 0 ? 'text-green-700' : 'text-red-600',
          )}
        >
          {balance >= 0 ? '+' : ''}{formatTimesheetMinutes(balance)}
        </div>
      )}
    </>
  )

  const className = cn(
    'flex h-full flex-col rounded-lg border p-2 transition-colors',
    compact ? 'min-h-[4.5rem]' : 'min-h-28',
    TIMESHEET_DAY_CARD_CLASS[kind],
    overtimeAttention && 'ring-1 ring-violet-300/80',
    isToday && 'ring-2 ring-primary/40',
    clickable && 'cursor-pointer hover:brightness-[0.98]',
  )

  if (clickable) {
    return (
      <button
        type="button"
        className={cn(className, 'w-full text-left')}
        onClick={() => onDayClick!(day.work_date)}
      >
        {inner}
      </button>
    )
  }

  return <div className={className}>{inner}</div>
}

function TimesheetWeekGrid({
  dates,
  dayMap,
  dowLabels,
  typeConfigMap,
  employeeId,
  siteId,
  canManage,
  formatDate,
  onDayClick,
  t,
}: {
  dates: string[]
  dayMap: Map<string, TimesheetDayRow>
  dowLabels: string[]
  typeConfigMap: Record<string, AbsenceTypeConfig>
  employeeId: string
  siteId?: string
  canManage: boolean
  formatDate: (iso: string) => string
  onDayClick?: (workDate: string) => void
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  return (
    <div className="grid grid-cols-2 items-stretch gap-2 sm:grid-cols-4 lg:grid-cols-7">
      {dates.map((date) => {
        const d = new Date(`${date}T12:00:00`)
        const dow = dowLabels[(d.getDay() + 6) % 7] ?? ''
        const day = dayMap.get(date) ?? emptyTimesheetDay(date)
        return (
          <div key={date} className="flex min-h-0 flex-col">
            <div className="shrink-0 text-center text-[10px] font-medium uppercase tracking-wide text-muted-foreground">
              {dow}
            </div>
            <div className="mt-1 flex flex-1 flex-col">
              <TimesheetDayCard
                day={day}
                compact
                typeConfigMap={typeConfigMap}
                employeeId={employeeId}
                siteId={siteId}
                canManage={canManage}
                formatDate={formatDate}
                onDayClick={onDayClick}
                t={t}
              />
            </div>
          </div>
        )
      })}
    </div>
  )
}

function TimesheetListTable({
  days,
  typeConfigMap,
  employeeId,
  siteId,
  canManage,
  formatDate,
  onDayClick,
  dateCellColored = false,
  punchContext,
  punchDiscrepancyToleranceMin,
  t,
}: {
  days: TimesheetDayRow[]
  typeConfigMap: Record<string, AbsenceTypeConfig>
  employeeId: string
  siteId?: string
  canManage: boolean
  formatDate: (iso: string) => string
  onDayClick?: (workDate: string) => void
  dateCellColored?: boolean
  punchContext: EmployeeTimesheetPunchContext
  punchDiscrepancyToleranceMin: number
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const absenceHref = canManage ? employeeAbsencesUrl(employeeId) : undefined

  return (
    <div className="overflow-x-auto rounded-md border">
      <table className="w-full text-sm">
        <thead className="bg-muted/40">
          <tr>
            <th className="px-3 py-2 text-left font-medium">{t('admin.col_date', 'Data')}</th>
            <th className="px-3 py-2 text-left font-medium">{t('payroll_review.col_day_type', 'Tipus dia')}</th>
            <th className="px-3 py-2 text-left font-medium min-w-[10rem]">
              {t('timesheet.col_punches_detail', 'Fitxatges')}
            </th>
            <th className="px-3 py-2 text-left font-medium">{t('payroll_review.col_absence', 'Absència / IT')}</th>
            <th className="px-3 py-2 text-right font-medium">{t('admin.col_worked', 'Treballat')}</th>
            <th className="px-3 py-2 text-right font-medium">{t('admin.col_expected', 'Previst')}</th>
            <th className="px-3 py-2 text-right font-medium">{t('admin.col_balance', 'Balanç')}</th>
            <th className="px-3 py-2 text-center font-medium">{t('status_layers.col_entry', 'Jornada')}</th>
            <th className="px-3 py-2 text-center font-medium">{t('status_layers.col_summary', 'Dia nòmina')}</th>
          </tr>
        </thead>
        <tbody>
          {days.map((day) => {
            const balance =
              day.expected_minutes != null ? day.worked_minutes - day.expected_minutes : null
            const hasActivity = day.punch_count > 0 || day.worked_minutes > 0
            const kind = resolveTimesheetDayVisualKind(day)
            const clickable = Boolean(onDayClick)
            return (
              <tr
                key={day.work_date}
                className={cn(
                  'border-t',
                  !dateCellColored && TIMESHEET_DAY_CARD_CLASS[kind],
                  clickable && 'cursor-pointer hover:bg-muted/30',
                )}
                onClick={clickable ? () => onDayClick!(day.work_date) : undefined}
                onKeyDown={
                  clickable
                    ? (e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault()
                          onDayClick!(day.work_date)
                        }
                      }
                    : undefined
                }
                tabIndex={clickable ? 0 : undefined}
                role={clickable ? 'button' : undefined}
              >
                <td
                  className={cn(
                    'px-3 py-2 text-xs font-medium tabular-nums',
                    dateCellColored && cn('border-r', TIMESHEET_DAY_CARD_CLASS[kind]),
                  )}
                >
                  {formatDate(day.work_date)}
                </td>
                <td className="px-3 py-2 text-xs">
                  {t(timesheetDayTypeLabelKey(day.day_type), day.day_type ?? '—')}
                  {day.holiday_name ? (
                    <span className="mt-0.5 block text-muted-foreground">{day.holiday_name}</span>
                  ) : null}
                </td>
                <td className="px-3 py-2">
                  <TimesheetDayPunchesCell
                    day={day}
                    punches={punchContext.punchesByDate.get(day.work_date) ?? []}
                    schedule={punchContext.scheduleByDate.get(day.work_date)}
                    adjustment={punchContext.adjustmentByDate.get(day.work_date)}
                    toleranceMinutes={punchDiscrepancyToleranceMin}
                    t={t}
                  />
                </td>
                <td className="px-3 py-2 text-xs">
                  {day.is_it && day.absence_id ? (
                    <AbsenceItBadge
                      isIt
                      absenceType={day.absence_type}
                      typeConfigMap={typeConfigMap}
                      href={absenceHref}
                    />
                  ) : day.absence_id ? (
                    <AbsenceItBadge
                      isIt={false}
                      absenceType={day.absence_type}
                      typeConfigMap={typeConfigMap}
                      href={absenceHref}
                    />
                  ) : (
                    '—'
                  )}
                </td>
                <td className="px-3 py-2 text-right tabular-nums">
                  {hasActivity ? formatTimesheetMinutes(day.worked_minutes) : '—'}
                </td>
                <td className="px-3 py-2 text-right tabular-nums text-muted-foreground">
                  {formatTimesheetMinutes(day.expected_minutes)}
                </td>
                <td
                  className={cn(
                    'px-3 py-2 text-right font-medium tabular-nums',
                    balance != null && (balance >= 0 ? 'text-green-700' : 'text-red-600'),
                  )}
                >
                  {balance != null ? formatTimesheetMinutes(balance) : '—'}
                </td>
                <td className="px-3 py-2 text-center">
                  {isTimesheetReviewPendingDay(day) ? (
                    <TimesheetReviewPendingBadge
                      day={day}
                      employeeId={employeeId}
                      siteId={siteId}
                      canManage={canManage}
                      t={t}
                    />
                  ) : day.entry_status ? (
                    <AttendanceLayerStatusBadge
                      status={day.entry_status}
                      layer="entry"
                      t={t}
                    />
                  ) : (
                    '—'
                  )}
                </td>
                <td className="px-3 py-2 text-center">
                  {day.summary_status ? (
                    <AttendanceLayerStatusBadge
                      status={day.summary_status}
                      layer="summary"
                      t={t}
                    />
                  ) : (
                    '—'
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
