import { AlertTriangle, OctagonAlert, Pencil } from 'lucide-react'
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip'
import type { TimePunch } from '../api/attendanceService'
import { formatDayDetailTime } from '../api/dayDetailService'
import type { TimesheetDayRow } from '../api/timesheetService'
import type { TimesheetDayAdjustment } from '../api/useEmployeeTimesheetPunches'
import type { ResolvedWorkDay } from '../api/workDayResolveService'
import { formatTimesheetMinutes } from '../api/timesheetService'
import {
  resolveScheduleTimingAlert,
  type ScheduleTimingAlertKind,
} from '../utils/punchDiscrepancyUtils'
import {
  anomalyHelp,
  anomalyLabel,
  isTimesheetMissingRecordDay,
  resolveDayLevelCriticalAnomalies,
  resolvePunchCriticalMarkers,
} from '../utils/timesheetPunchIncidents'
import { PunchTypeIcon } from './PunchTypeIcon'

function formatPunchTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('ca-ES', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  })
}

function alertLabelKey(kind: ScheduleTimingAlertKind): string {
  switch (kind) {
    case 'early_in':
      return 'timesheet.punch_alert_early_in'
    case 'late_in':
      return 'timesheet.punch_alert_late_in'
    case 'early_out':
      return 'timesheet.punch_alert_early_out'
    case 'late_out':
      return 'timesheet.punch_alert_late_out'
  }
}

function alertLabelFallback(kind: ScheduleTimingAlertKind): string {
  switch (kind) {
    case 'early_in':
      return 'Entrada anticipada'
    case 'late_in':
      return 'Entrada tardana'
    case 'early_out':
      return 'Sortida anticipada'
    case 'late_out':
      return 'Sortida tardana'
  }
}

function TimesheetAdjustmentIcon({
  adjustment,
  t,
}: {
  adjustment: TimesheetDayAdjustment
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const hasBreak = (adjustment.break_minutes ?? 0) > 0
  const hasTimes = adjustment.starts_at || adjustment.ends_at

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="inline-flex rounded p-0.5 text-violet-600 hover:bg-violet-100/80"
          aria-label={t('timesheet.adjustment_aria', 'Hores ajustades')}
          onClick={(e) => e.stopPropagation()}
        >
          <Pencil className="h-3.5 w-3.5" aria-hidden />
        </button>
      </TooltipTrigger>
      <TooltipContent side="top" className="max-w-xs space-y-1 text-xs leading-relaxed">
        <p className="font-medium">
          {t('timesheet.adjustment_title', 'Hores ajustades per gestor')}
        </p>
        {adjustment.net_minutes != null && (
          <p>
            {t('timesheet.adjustment_net', 'Net')}:{' '}
            <span className="font-medium tabular-nums">
              {formatTimesheetMinutes(adjustment.net_minutes)}
            </span>
          </p>
        )}
        {hasBreak && (
          <p>
            {t('timesheet.adjustment_break', 'Pausa')}:{' '}
            <span className="font-medium tabular-nums">
              {formatTimesheetMinutes(adjustment.break_minutes)}
            </span>
          </p>
        )}
        {hasTimes && (
          <p className="tabular-nums">
            {t('timesheet.adjustment_times', 'Entrada — Sortida')}:{' '}
            {formatDayDetailTime(adjustment.starts_at)} — {formatDayDetailTime(adjustment.ends_at)}
          </p>
        )}
        {adjustment.adjustment_note ? (
          <p className="text-muted-foreground">
            {t('day_detail.adjustment_note', 'Ajust')}: {adjustment.adjustment_note}
          </p>
        ) : null}
      </TooltipContent>
    </Tooltip>
  )
}

function CriticalIncidentIcon({
  code,
  t,
}: {
  code: string
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const label = anomalyLabel(code, t)
  const help = anomalyHelp(code, t)

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="inline-flex items-center gap-0.5 rounded px-0.5 text-destructive hover:bg-destructive/10"
          aria-label={label}
          onClick={(e) => e.stopPropagation()}
        >
          <OctagonAlert className="h-4 w-4 shrink-0" aria-hidden />
        </button>
      </TooltipTrigger>
      <TooltipContent side="top" className="max-w-xs text-xs leading-relaxed">
        <p className="font-medium text-destructive">{label}</p>
        {help ? <p className="mt-1 text-muted-foreground">{help}</p> : null}
      </TooltipContent>
    </Tooltip>
  )
}

function ScheduleTimingIcon({
  kind,
  t,
}: {
  kind: ScheduleTimingAlertKind
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}) {
  const label = t(alertLabelKey(kind), alertLabelFallback(kind))
  return (
    <span className="inline-flex text-amber-600" title={label} aria-label={label}>
      <AlertTriangle className="h-3.5 w-3.5" aria-hidden />
    </span>
  )
}

export interface TimesheetDayPunchesCellProps {
  day: TimesheetDayRow
  punches: TimePunch[]
  schedule: ResolvedWorkDay | null | undefined
  adjustment?: TimesheetDayAdjustment | null
  toleranceMinutes: number
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string
}

export function TimesheetDayPunchesCell({
  day,
  punches,
  schedule,
  adjustment,
  toleranceMinutes,
  t,
}: TimesheetDayPunchesCellProps) {
  const intervals = schedule?.intervals ?? []
  const missingRecord = isTimesheetMissingRecordDay(day)
  const punchMarkers = resolvePunchCriticalMarkers(
    punches,
    day.anomaly_codes,
    day.entry_status,
  )
  const dayLevelAnomalies = resolveDayLevelCriticalAnomalies(day.anomaly_codes, punchMarkers)
  const hasAdjustment = Boolean(adjustment)
  const hasContent =
    missingRecord || punches.length > 0 || hasAdjustment || dayLevelAnomalies.length > 0

  if (!hasContent) {
    return <span className="text-muted-foreground">—</span>
  }

  return (
    <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
      {missingRecord ? (
        <span className="text-xs font-medium text-orange-800">
          {t('timesheet.missing_punch', 'Falta registre')}
        </span>
      ) : null}

      {punches.map((punch, index) => {
        if (!punch.occurred_at) return null
        const punchType = punch.punch_type ?? 'in'
        const occurredAt = new Date(punch.occurred_at)
        const criticalCode = punch.id ? punchMarkers.get(punch.id) : undefined
        const scheduleAlert =
          !criticalCode &&
          resolveScheduleTimingAlert(punchType, occurredAt, intervals, toleranceMinutes)

        return (
          <span
            key={punch.id ?? `${punchType}-${punch.occurred_at}-${index}`}
            className="inline-flex items-center gap-0.5 tabular-nums"
          >
            <PunchTypeIcon punchType={punchType} />
            <span className="text-xs">{formatPunchTime(punch.occurred_at)}</span>
            {criticalCode ? (
              <CriticalIncidentIcon code={criticalCode} t={t} />
            ) : scheduleAlert ? (
              <ScheduleTimingIcon kind={scheduleAlert} t={t} />
            ) : null}
          </span>
        )
      })}

      {dayLevelAnomalies.map((code) => (
        <span key={code} className="inline-flex items-center gap-1">
          <CriticalIncidentIcon code={code} t={t} />
          <span className="text-xs font-medium text-destructive">{anomalyLabel(code, t)}</span>
        </span>
      ))}

      {adjustment ? <TimesheetAdjustmentIcon adjustment={adjustment} t={t} /> : null}
    </div>
  )
}
