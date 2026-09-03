import { useTranslation } from 'react-i18next'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { firstDayColumnOffset } from '@/lib/formatDatePattern'
import { DAY_STYLE, type ResolvedDay } from '../LaborCalendarGrid'
import { CalendarDayTooltip } from '../CalendarDayTooltip'
import type { PlannerActualRecord } from '../../api/schedulePlannerService'
import { detectDiscrepancy } from '../../api/schedulePlannerFilters'
import { ScheduleDiscrepancyBadge } from './ScheduleDiscrepancyBadge'

function toDateStr(year: number, month: number, day: number): string {
  return `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

function daysInMonth(year: number, month: number): number {
  return new Date(year, month + 1, 0).getDate()
}

interface ScheduleMonthMiniBlockProps {
  year: number
  month: number
  weekStartsOn: number
  days: Record<string, ResolvedDay>
  employeeId?: string
  actuals?: Map<string, PlannerActualRecord>
  isReference?: boolean
}

export function ScheduleMonthMiniBlock({
  year,
  month,
  weekStartsOn,
  days,
  employeeId,
  actuals,
  isReference = false,
}: ScheduleMonthMiniBlockProps) {
  const { t } = useTranslation('attendance')
  const { dateFormat } = useCalendarDisplaySettings()
  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')

  const offset = firstDayColumnOffset(year, month, weekStartsOn)
  const cells: (string | null)[] = []
  for (let i = 0; i < offset; i++) cells.push(null)
  for (let d = 1; d <= daysInMonth(year, month); d++) cells.push(toDateStr(year, month, d))

  return (
    <div className="grid grid-cols-7 gap-px" style={{ width: 84 }}>
      {cells.map((date, i) => {
        if (!date) {
          return <div key={`e${i}`} className="h-2.5 w-2.5" />
        }

        const state: ResolvedDay = days[date] ?? {
          date,
          type: 'undefined',
          intervals: [],
          source: 'none',
        }
        const s = DAY_STYLE[state.type]
        const actual = employeeId && actuals ? actuals.get(`${employeeId}|${date}`) : undefined
        const actualsLoaded = actuals !== undefined
        const discrepancy = actualsLoaded && !isReference && employeeId
          ? detectDiscrepancy(state, actual, undefined, true)
          : null

        const cell = (
          <div className="relative h-2.5 w-2.5">
            <div
              className={`h-2.5 w-2.5 rounded-[1px] ${s.legendMark} ${isReference ? 'ring-1 ring-inset ring-border/40' : ''}`}
            />
            {discrepancy && (
              <span className="absolute -right-0.5 -top-0.5 scale-75">
                <ScheduleDiscrepancyBadge type={discrepancy} compact />
              </span>
            )}
          </div>
        )

        return (
          <CalendarDayTooltip
            key={date}
            state={state}
            dateFormat={dateFormat}
            overnightSuffix={overnightSuffix}
            t={t}
            side="top"
          >
            {cell}
          </CalendarDayTooltip>
        )
      })}
    </div>
  )
}
