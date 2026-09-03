import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'
import type { PlannerViewMode } from './SchedulePlannerToolbar'

const selectClass =
  'h-8 w-full rounded-md border border-input bg-background px-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring'

interface SchedulePeriodPickerProps {
  anchor: Date
  viewMode: PlannerViewMode
  months: string[]
  periodLabel: string
  isRefreshing?: boolean
  onApply: (date: Date) => void
}

function toDateInputValue(d: Date): string {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

export function SchedulePeriodPicker({
  anchor,
  viewMode,
  months,
  periodLabel,
  isRefreshing = false,
  onApply,
}: SchedulePeriodPickerProps) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)
  const [draftMonth, setDraftMonth] = useState(anchor.getMonth())
  const [draftYear, setDraftYear] = useState(anchor.getFullYear())
  const [draftDate, setDraftDate] = useState(toDateInputValue(anchor))

  useEffect(() => {
    if (!open) return
    setDraftMonth(anchor.getMonth())
    setDraftYear(anchor.getFullYear())
    setDraftDate(toDateInputValue(anchor))
  }, [open, anchor])

  function handleApply() {
    const d = new Date(anchor)
    if (viewMode === 'year') {
      d.setFullYear(draftYear)
      d.setMonth(0)
      d.setDate(1)
    } else if (viewMode === 'week') {
      const picked = new Date(`${draftDate}T12:00:00`)
      if (Number.isNaN(picked.getTime())) return
      onApply(picked)
      setOpen(false)
      return
    } else {
      d.setFullYear(draftYear)
      d.setMonth(draftMonth)
      d.setDate(1)
    }
    onApply(d)
    setOpen(false)
  }

  const yearOptions = buildYearRange(anchor.getFullYear())

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          type="button"
          className={cn(
            'inline-flex min-w-[8rem] items-center justify-center gap-1.5 rounded-md px-2 py-1 text-sm font-medium tabular-nums',
            'hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring',
          )}
          aria-label={t('schedule_planner.jump_to_period', 'Anar al període')}
        >
          {periodLabel}
          {isRefreshing && (
            <span className="inline-flex h-3.5 w-3.5 animate-spin rounded-full border-2 border-muted-foreground border-t-transparent" />
          )}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-56 space-y-3 p-3" align="start">
        {viewMode === 'month' && (
          <div className="space-y-2">
            <label className="text-xs font-medium text-muted-foreground">
              {t('schedule_planner.pick_month', 'Mes')}
            </label>
            <select
              className={selectClass}
              value={draftMonth}
              onChange={(e) => setDraftMonth(Number(e.target.value))}
            >
              {months.map((name, i) => (
                <option key={name} value={i}>{name}</option>
              ))}
            </select>
            <label className="text-xs font-medium text-muted-foreground">
              {t('schedule_planner.pick_year', 'Any')}
            </label>
            <select
              className={selectClass}
              value={draftYear}
              onChange={(e) => setDraftYear(Number(e.target.value))}
            >
              {yearOptions.map((y) => (
                <option key={y} value={y}>{y}</option>
              ))}
            </select>
          </div>
        )}

        {viewMode === 'year' && (
          <div className="space-y-2">
            <label className="text-xs font-medium text-muted-foreground">
              {t('schedule_planner.pick_year', 'Any')}
            </label>
            <select
              className={selectClass}
              value={draftYear}
              onChange={(e) => setDraftYear(Number(e.target.value))}
            >
              {yearOptions.map((y) => (
                <option key={y} value={y}>{y}</option>
              ))}
            </select>
          </div>
        )}

        {viewMode === 'week' && (
          <div className="space-y-2">
            <label className="text-xs font-medium text-muted-foreground">
              {t('schedule_planner.pick_date', 'Data dins la setmana')}
            </label>
            <input
              type="date"
              className={selectClass}
              value={draftDate}
              onChange={(e) => setDraftDate(e.target.value)}
            />
          </div>
        )}

        <Button type="button" size="sm" className="w-full" onClick={handleApply}>
          {t('schedule_planner.go', 'Anar')}
        </Button>
      </PopoverContent>
    </Popover>
  )
}

function buildYearRange(centerYear: number): number[] {
  const start = centerYear - 10
  const end = centerYear + 10
  const years: number[] = []
  for (let y = start; y <= end; y += 1) years.push(y)
  return years
}
