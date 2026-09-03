import type { TFunction } from 'i18next'
import { cn } from '@/lib/utils'
import { DAY_STYLE, type ResolvedDay } from '../LaborCalendarGrid'
import { CalendarDayTooltip } from '../CalendarDayTooltip'
import {
  formatIntervalsList,
  formatWorkDuration,
  totalWorkMinutes,
} from '../../api/workIntervals'
import type { PlannerActualRecord } from '../../api/schedulePlannerService'
import type { PlannerDiscrepancyType } from '../../api/schedulePlannerFilters'
import type { PlannerDataMode } from './SchedulePlannerToolbar'
import { ScheduleDiscrepancyBadge } from './ScheduleDiscrepancyBadge'

export type ScheduleCellVariant = 'compact' | 'expanded' | 'mini'

interface ScheduleDayCellProps {
  state: ResolvedDay | undefined
  variant?: ScheduleCellVariant
  dataMode?: PlannerDataMode
  actual?: PlannerActualRecord | null
  discrepancy?: PlannerDiscrepancyType | null
  dateFormat: string
  overnightSuffix: string
  t: TFunction
  isReference?: boolean
}

export function ScheduleDayCell({
  state,
  variant = 'compact',
  dataMode = 'planned',
  actual,
  discrepancy,
  dateFormat,
  overnightSuffix,
  t,
  isReference = false,
}: ScheduleDayCellProps) {
  const resolved: ResolvedDay = state ?? {
    date: '',
    type: 'undefined',
    intervals: [],
    source: 'none',
  }
  const s = DAY_STYLE[resolved.type]
  const plannedMin = resolved.type === 'work' ? totalWorkMinutes(resolved.intervals) : 0
  const workedMin = actual?.worked_minutes ?? 0
  const punchCount = actual?.punch_count ?? 0
  const hasActual = punchCount > 0 || workedMin > 0
  const typeLabel = t(`labor_cal.type_${resolved.type}`, s.label)

  if (variant === 'expanded' && dataMode === 'actual' && !isReference && (state?.date || hasActual)) {
    return (
      <div className="flex min-h-16 w-full flex-col items-center justify-center gap-0.5 rounded-sm border bg-slate-50 px-1 py-1 text-center">
        <span className="text-sm font-semibold tabular-nums">{formatWorkDuration(workedMin)}</span>
        <span className="text-[9px] text-muted-foreground tabular-nums">
          {t('schedule_planner.punch_count', '{{count}} fitx.', { count: punchCount })}
        </span>
      </div>
    )
  }

  if (!state?.date) {
    return <div className={cn(variant === 'compact' && 'h-9 w-9', variant === 'expanded' && 'min-h-16')} />
  }

  if (variant === 'expanded' && dataMode === 'compare' && !isReference) {
    const content = (
      <div className="flex min-h-[4.5rem] w-full min-w-[88px] flex-col gap-0.5 rounded-sm border p-0.5">
        <div className={cn('rounded px-1 py-0.5 text-[9px] leading-tight', s.cell)}>
          <div className="font-medium">{typeLabel}</div>
          {resolved.type === 'work' && resolved.intervals.length > 0 && (
            <div className="mt-0.5 tabular-nums opacity-90">
              {formatIntervalsList(resolved.intervals, overnightSuffix)}
            </div>
          )}
          {plannedMin > 0 && (
            <div className="mt-0.5 font-semibold tabular-nums">
              {formatWorkDuration(plannedMin)}
            </div>
          )}
        </div>
        <div className="rounded bg-muted/60 px-1 py-0.5 text-center text-[9px]">
          <span className="text-muted-foreground">{t('schedule_planner.actual_short', 'Real')}: </span>
          <span className="font-semibold tabular-nums">{formatWorkDuration(workedMin)}</span>
        </div>
        {discrepancy && (
          <div className="flex justify-center">
            <ScheduleDiscrepancyBadge type={discrepancy} compact />
          </div>
        )}
      </div>
    )
    return (
      <CalendarDayTooltip state={resolved} dateFormat={dateFormat} overnightSuffix={overnightSuffix} t={t} side="top">
        {content}
      </CalendarDayTooltip>
    )
  }

  if (variant === 'expanded') {
    const content = (
      <div
        className={cn(
          'flex min-h-16 w-full min-w-[80px] flex-col items-start justify-center gap-0.5 rounded-sm px-1.5 py-1 text-[10px] leading-tight',
          s.cell,
          isReference && 'ring-1 ring-inset ring-border/50',
        )}
      >
        <span className="font-medium">{typeLabel}</span>
        {resolved.name && <span className="truncate opacity-80">{resolved.name}</span>}
        {resolved.type === 'work' && resolved.intervals.length > 0 && (
          <span className="tabular-nums opacity-90">
            {formatIntervalsList(resolved.intervals, overnightSuffix)}
          </span>
        )}
        {plannedMin > 0 && (
          <span className="font-semibold tabular-nums">{formatWorkDuration(plannedMin)}</span>
        )}
      </div>
    )
    return (
      <CalendarDayTooltip state={resolved} dateFormat={dateFormat} overnightSuffix={overnightSuffix} t={t} side="top">
        {content}
      </CalendarDayTooltip>
    )
  }

  const compactCell = (
    <div className="relative">
      <div
        className={cn(
          'flex flex-col items-center justify-center rounded-sm',
          variant === 'compact' && 'h-9 w-9 min-w-9',
          variant === 'mini' && 'h-4 w-4 min-w-4',
          s.cell,
          isReference && 'ring-1 ring-inset ring-border/50',
        )}
        title={resolved.name}
      >
        {resolved.type === 'work' && plannedMin > 0 && variant === 'compact' && (
          <span className="text-[8px] font-semibold leading-none tabular-nums">
            {formatWorkDuration(plannedMin)}
          </span>
        )}
      </div>
      {discrepancy && (variant === 'compact' || variant === 'mini') && (
        <span className="absolute -right-0.5 -top-0.5">
          <ScheduleDiscrepancyBadge type={discrepancy} compact />
        </span>
      )}
    </div>
  )

  return (
    <CalendarDayTooltip state={resolved} dateFormat={dateFormat} overnightSuffix={overnightSuffix} t={t} side="top">
      {compactCell}
    </CalendarDayTooltip>
  )
}
