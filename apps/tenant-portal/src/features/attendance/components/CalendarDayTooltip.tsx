import type { ReactNode } from 'react'
import type { TFunction } from 'i18next'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { formatIsoDateWithPattern } from '@/lib/formatDatePattern'
import type { TenantDayType } from '../api/useLaborCalendar'
import {
  formatIntervalsList,
  totalWorkMinutes,
  formatWorkDuration,
} from '../api/workIntervals'
import type { ResolvedDay } from './LaborCalendarGrid'

const TYPE_LABEL_FALLBACK: Record<TenantDayType, string> = {
  work: 'Laboral',
  holiday: 'Festiu',
  vacation: 'Vacances',
  undefined: 'Indefinit',
}

export function DayTooltipContent({
  state,
  dateFormat,
  overnightSuffix,
  t,
}: {
  state: ResolvedDay
  dateFormat: string
  overnightSuffix: string
  t: TFunction
}) {
  const formatted = formatIsoDateWithPattern(state.date, dateFormat)
  const typeLabel = t(`labor_cal.type_${state.type}`, TYPE_LABEL_FALLBACK[state.type])
  const workMinutes = state.type === 'work' ? totalWorkMinutes(state.intervals) : 0

  return (
    <div className="space-y-1 text-xs leading-snug">
      <p className="font-semibold">{formatted}</p>
      <p>{typeLabel}</p>
      {state.source === 'assigned_holiday' && (
        <p className="text-muted-foreground">
          {t('labor_cal.source_assigned_holiday', 'Festiu de calendari assignat')}
        </p>
      )}
      {state.name && <p>{state.name}</p>}
      {state.type === 'work' && state.intervals.length > 0 && (
        <>
          <p className="tabular-nums">
            <span className="text-muted-foreground">{t('labor_cal.work_intervals', 'Horari')}: </span>
            {formatIntervalsList(state.intervals, overnightSuffix)}
          </p>
          <p>
            <span className="text-muted-foreground">{t('labor_cal.work_hours_total', 'Hores de treball')}: </span>
            <span className="font-medium tabular-nums">{formatWorkDuration(workMinutes)}</span>
          </p>
        </>
      )}
    </div>
  )
}

export function CalendarDayTooltip({
  state,
  dateFormat,
  overnightSuffix,
  t,
  children,
  side = 'top',
}: {
  state: ResolvedDay
  dateFormat: string
  overnightSuffix: string
  t: TFunction
  children: ReactNode
  side?: 'top' | 'bottom' | 'left' | 'right'
}) {
  return (
    <Tooltip delayDuration={250}>
      <TooltipTrigger asChild>{children}</TooltipTrigger>
      <TooltipContent side={side} className="max-w-xs">
        <DayTooltipContent
          state={state}
          dateFormat={dateFormat}
          overnightSuffix={overnightSuffix}
          t={t}
        />
      </TooltipContent>
    </Tooltip>
  )
}
