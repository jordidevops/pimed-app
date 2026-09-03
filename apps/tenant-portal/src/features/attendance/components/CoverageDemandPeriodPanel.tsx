import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useCalendarDisplaySettings } from '@/hooks/useCalendarDisplaySettings'
import { firstDayColumnOffset, weekColumnOrder } from '@/lib/formatDatePattern'
import { useFormatAttendanceDate } from '../hooks/useFormatAttendanceDate'
import { useCoverageForPeriod } from '../api/useShifts'
import type { CoverageDemand } from '../api/useCoverageDemands'

type PeriodMode = 'week' | 'month'

function todayISO(): string {
  const d = new Date()
  return toISODate(d)
}

function toISODate(d: Date): string {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function parseISODate(iso: string): Date {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  return new Date(y, m - 1, d)
}

function addDays(date: Date, n: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + n)
  return d
}

function getWeekStart(date: Date, weekStartsOn: number): Date {
  const d = new Date(date)
  d.setHours(0, 0, 0, 0)
  const offset = (d.getDay() - weekStartsOn + 7) % 7
  d.setDate(d.getDate() - offset)
  return d
}

function demandAppliesOn(d: CoverageDemand, iso: string): boolean {
  if (!d.is_active) return false
  const day = iso.slice(0, 10)
  const from = d.effective_from?.slice(0, 10)
  const to = d.effective_to?.slice(0, 10)
  if (from && day < from) return false
  if (to && day > to) return false
  if (d.kind === 'extraordinary') return (d.demand_date?.slice(0, 10) ?? '') === day
  const dt = parseISODate(day)
  return d.day_of_week === dt.getDay()
}

function cellClass(required: number, selected: boolean): string {
  const base =
    'flex flex-col items-center justify-center rounded-md border text-xs transition-colors min-h-14'
  const selectedCls = selected ? 'ring-2 ring-primary ring-offset-1' : ''
  if (required <= 0) {
    return `${base} ${selectedCls} bg-muted/40 text-muted-foreground border-border`
  }
  if (required <= 2) {
    return `${base} ${selectedCls} bg-emerald-50 text-emerald-800 border-emerald-200 dark:bg-emerald-950/40 dark:text-emerald-100`
  }
  if (required <= 5) {
    return `${base} ${selectedCls} bg-emerald-100 text-emerald-900 border-emerald-300 dark:bg-emerald-900/50 dark:text-emerald-50`
  }
  return `${base} ${selectedCls} bg-emerald-200 text-emerald-950 border-emerald-400 dark:bg-emerald-800/60 dark:text-emerald-50`
}

function dayLabel(
  required: number,
  extraTarget: number,
): string {
  if (required <= 0) return '—'
  const base = Math.max(0, required - extraTarget)
  if (extraTarget > 0 && base > 0) return `${base}+${extraTarget}E`
  if (extraTarget > 0) return `${extraTarget}E`
  return String(required)
}

export function CoverageDemandPeriodPanel({
  selectedDate,
  onSelectDate,
  demands,
}: {
  selectedDate: string
  onSelectDate: (iso: string) => void
  demands: CoverageDemand[]
}) {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const { weekStartsOn } = useCalendarDisplaySettings()
  const [mode, setMode] = useState<PeriodMode>('week')
  const [anchor, setAnchor] = useState(() => parseISODate(selectedDate || todayISO()))

  const weekStart = useMemo(
    () => getWeekStart(anchor, weekStartsOn),
    [anchor, weekStartsOn],
  )
  const weekDays = useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)),
    [weekStart],
  )

  const monthYear = anchor.getFullYear()
  const monthIndex = anchor.getMonth()
  const monthStart = useMemo(
    () => new Date(monthYear, monthIndex, 1),
    [monthYear, monthIndex],
  )
  const monthEnd = useMemo(
    () => new Date(monthYear, monthIndex + 1, 0),
    [monthYear, monthIndex],
  )

  const rangeFrom = mode === 'week' ? toISODate(weekDays[0]) : toISODate(monthStart)
  const rangeTo = mode === 'week' ? toISODate(weekDays[6]) : toISODate(monthEnd)

  const { data: coverage = [], isLoading } = useCoverageForPeriod(rangeFrom, rangeTo)

  const coverageByDate = useMemo(() => {
    const map: Record<string, number> = {}
    for (const day of coverage) {
      if (!day.work_date) continue
      map[day.work_date.slice(0, 10)] = day.required_employee_count
    }
    return map
  }, [coverage])

  const extraByDate = useMemo(() => {
    const map: Record<string, number> = {}
    const start = parseISODate(rangeFrom)
    const end = parseISODate(rangeTo)
    for (let d = new Date(start); d <= end; d = addDays(d, 1)) {
      const iso = toISODate(d)
      let sum = 0
      for (const demand of demands) {
        if (demand.kind !== 'extraordinary') continue
        if (demandAppliesOn(demand, iso)) sum += demand.required_target
      }
      if (sum > 0) map[iso] = sum
    }
    return map
  }, [demands, rangeFrom, rangeTo])

  const dowAbbr = useMemo(() => {
    const labels = [
      t('calendar.days.sun', 'Dg'),
      t('calendar.days.mon', 'Dl'),
      t('calendar.days.tue', 'Dt'),
      t('calendar.days.wed', 'Dc'),
      t('calendar.days.thu', 'Dj'),
      t('calendar.days.fri', 'Dv'),
      t('calendar.days.sat', 'Ds'),
    ]
    return weekColumnOrder(weekStartsOn).map((dow) => labels[dow])
  }, [t, weekStartsOn])

  const monthCells = useMemo(() => {
    const offset = firstDayColumnOffset(monthYear, monthIndex, weekStartsOn)
    const daysInMonth = monthEnd.getDate()
    const cells: Array<{ iso: string | null; dayNum: number | null }> = []
    for (let i = 0; i < offset; i++) cells.push({ iso: null, dayNum: null })
    for (let day = 1; day <= daysInMonth; day++) {
      const iso = toISODate(new Date(monthYear, monthIndex, day))
      cells.push({ iso, dayNum: day })
    }
    while (cells.length % 7 !== 0) cells.push({ iso: null, dayNum: null })
    return cells
  }, [monthYear, monthIndex, monthEnd, weekStartsOn])

  const yearMonthChips = useMemo(() => {
    return Array.from({ length: 12 }, (_, m) => {
      const start = new Date(monthYear, m, 1)
      const end = new Date(monthYear, m + 1, 0)
      let hasDemand = false
      let gapDays = 0
      let totalDays = 0
      for (let d = new Date(start); d <= end; d = addDays(d, 1)) {
        totalDays += 1
        const iso = toISODate(d)
        const applies = demands.some((demand) => demandAppliesOn(demand, iso))
        if (applies) hasDemand = true
        else gapDays += 1
      }
      return { month: m, hasDemand, gapDays, totalDays }
    })
  }, [demands, monthYear])

  const monthsWithGaps = yearMonthChips.filter((c) => !c.hasDemand).length

  const monthNames = useMemo(
    () =>
      Array.from({ length: 12 }, (_, m) =>
        new Date(2000, m, 1).toLocaleString(undefined, { month: 'short' }),
      ),
    [],
  )

  function goPrev() {
    if (mode === 'week') setAnchor((a) => addDays(a, -7))
    else setAnchor((a) => new Date(a.getFullYear(), a.getMonth() - 1, 1))
  }

  function goNext() {
    if (mode === 'week') setAnchor((a) => addDays(a, 7))
    else setAnchor((a) => new Date(a.getFullYear(), a.getMonth() + 1, 1))
  }

  function goToday() {
    const today = new Date()
    setAnchor(today)
    onSelectDate(toISODate(today))
  }

  function selectDay(iso: string) {
    onSelectDate(iso)
    setAnchor(parseISODate(iso))
  }

  const rangeLabel =
    mode === 'week'
      ? `${formatDate(rangeFrom)} – ${formatDate(rangeTo)}`
      : `${monthNames[monthIndex]} ${monthYear}`

  return (
    <div className="space-y-3 rounded-lg border p-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h4 className="text-sm font-semibold">
            {t('planificacio.demand_period_title', 'Demanda per període')}
          </h4>
          <p className="text-xs text-muted-foreground">
            {t(
              'planificacio.demand_period_help',
              'Quins dies tenen demanda definida. Clic a un dia per veure la cobertura per franja.',
            )}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="inline-flex overflow-hidden rounded-md border text-xs">
            <button
              type="button"
              className={`px-2 py-1 ${mode === 'week' ? 'bg-accent font-medium' : 'hover:bg-muted/50'}`}
              onClick={() => setMode('week')}
            >
              {t('planificacio.demand_period_week', 'Setmana')}
            </button>
            <button
              type="button"
              className={`px-2 py-1 border-l ${mode === 'month' ? 'bg-accent font-medium' : 'hover:bg-muted/50'}`}
              onClick={() => setMode('month')}
            >
              {t('planificacio.demand_period_month', 'Mes')}
            </button>
          </div>
          <button
            type="button"
            onClick={goPrev}
            className="rounded-md p-1.5 hover:bg-accent"
            aria-label={t('planificacio.demand_period_prev', 'Anterior')}
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <span className="min-w-36 text-center text-xs font-medium">{rangeLabel}</span>
          <button
            type="button"
            onClick={goNext}
            className="rounded-md p-1.5 hover:bg-accent"
            aria-label={t('planificacio.demand_period_next', 'Següent')}
          >
            <ChevronRight className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={goToday}
            className="rounded-md border px-2 py-1 text-xs hover:bg-accent"
          >
            {t('planificacio.demand_period_today', 'Avui')}
          </button>
        </div>
      </div>

      {mode === 'month' && (
        <div className="space-y-1.5">
          <div className="flex flex-wrap gap-1">
            {yearMonthChips.map((chip) => (
              <button
                key={chip.month}
                type="button"
                onClick={() => setAnchor(new Date(monthYear, chip.month, 1))}
                className={[
                  'rounded px-1.5 py-0.5 text-[10px] border',
                  chip.month === monthIndex ? 'ring-1 ring-primary' : '',
                  chip.hasDemand
                    ? 'bg-emerald-50 border-emerald-200 text-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-100'
                    : 'bg-muted/40 border-border text-muted-foreground',
                ].join(' ')}
                title={
                  chip.hasDemand
                    ? t('planificacio.demand_period_month_has', 'Hi ha demanda aquest mes')
                    : t('planificacio.demand_period_month_empty', 'Sense demanda aquest mes')
                }
              >
                {monthNames[chip.month]}
              </button>
            ))}
          </div>
          <p className="text-[11px] text-muted-foreground">
            {t(
              'planificacio.demand_period_year_summary',
              '{{year}}: {{with}} mesos amb demanda · {{gaps}} sense',
              {
                year: monthYear,
                with: 12 - monthsWithGaps,
                gaps: monthsWithGaps,
              },
            )}
          </p>
        </div>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('common.loading', 'Carregant…')}</p>
      ) : mode === 'week' ? (
        <div className="grid grid-cols-7 gap-1">
          {weekDays.map((d, i) => {
            const iso = toISODate(d)
            const required = coverageByDate[iso] ?? 0
            const extra = extraByDate[iso] ?? 0
            return (
              <button
                key={iso}
                type="button"
                onClick={() => selectDay(iso)}
                className={cellClass(required, iso === selectedDate)}
                title={`${formatDate(iso)}: ${required}`}
              >
                <span className="text-[10px] text-muted-foreground">{dowAbbr[i]}</span>
                <span className="font-semibold">{dayLabel(required, extra)}</span>
                <span className="text-[10px] opacity-70">{d.getDate()}</span>
              </button>
            )
          })}
        </div>
      ) : (
        <div className="space-y-1">
          <div className="grid grid-cols-7 gap-1">
            {dowAbbr.map((label) => (
              <div key={label} className="text-center text-[10px] font-medium text-muted-foreground py-0.5">
                {label}
              </div>
            ))}
          </div>
          <div className="grid grid-cols-7 gap-1">
            {monthCells.map((cell, i) => {
              if (!cell.iso) {
                return <div key={`empty-${i}`} className="min-h-12" />
              }
              const required = coverageByDate[cell.iso] ?? 0
              const extra = extraByDate[cell.iso] ?? 0
              return (
                <button
                  key={cell.iso}
                  type="button"
                  onClick={() => selectDay(cell.iso!)}
                  className={cellClass(required, cell.iso === selectedDate)}
                  title={`${formatDate(cell.iso)}: ${required}`}
                >
                  <span className="text-[10px] opacity-70">{cell.dayNum}</span>
                  <span className="font-semibold leading-tight">{dayLabel(required, extra)}</span>
                </button>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}

export function buildDemandRulesSummary(
  demands: CoverageDemand[],
  monthIsoAnchor: string,
  dowShort: string[],
  t: (key: string, fallback: string, opts?: Record<string, unknown>) => string,
): string {
  const recurringDows = [
    ...new Set(
      demands
        .filter((d) => d.kind === 'recurring' && d.is_active && d.day_of_week != null)
        .map((d) => d.day_of_week as number),
    ),
  ].sort((a, b) => a - b)

  const anchor = parseISODate(monthIsoAnchor)
  const monthStart = toISODate(new Date(anchor.getFullYear(), anchor.getMonth(), 1))
  const monthEnd = toISODate(new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0))
  const extraThisMonth = demands.filter((d) => {
    if (d.kind !== 'extraordinary' || !d.is_active || !d.demand_date) return false
    const day = d.demand_date.slice(0, 10)
    return day >= monthStart && day <= monthEnd
  }).length

  const parts: string[] = []
  if (recurringDows.length > 0) {
    const labels = recurringDows.map((dow) => dowShort[dow] ?? String(dow))
    parts.push(
      t('planificacio.demand_summary_recurring', 'Recurrent: {{days}}', {
        days: labels.join(', '),
      }),
    )
  }
  if (extraThisMonth > 0) {
    parts.push(
      t('planificacio.demand_summary_extra', '{{n}} extraordinàries aquest mes', {
        n: extraThisMonth,
      }),
    )
  }
  if (parts.length === 0) {
    return t('planificacio.demand_summary_empty', 'Cap regla activa')
  }
  return parts.join(' · ')
}
