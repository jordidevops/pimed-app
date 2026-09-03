import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import { SchedulePeriodPicker } from './SchedulePeriodPicker'

export type PlannerViewMode = 'month' | 'week' | 'year'
export type PlannerDataMode = 'planned' | 'actual' | 'compare'

interface SchedulePlannerToolbarProps {
  viewMode: PlannerViewMode
  onViewModeChange: (mode: PlannerViewMode) => void
  dataMode: PlannerDataMode
  onDataModeChange: (mode: PlannerDataMode) => void
  anchor: Date
  months: string[]
  periodLabel: string
  isRefreshing?: boolean
  onAnchorChange: (date: Date) => void
  onPrev: () => void
  onNext: () => void
  onToday: () => void
}

export function SchedulePlannerToolbar({
  viewMode,
  onViewModeChange,
  dataMode,
  onDataModeChange,
  anchor,
  months,
  periodLabel,
  isRefreshing = false,
  onAnchorChange,
  onPrev,
  onNext,
  onToday,
}: SchedulePlannerToolbarProps) {
  const { t } = useTranslation('attendance')

  const viewOptions = [
    { value: 'month' as const, label: t('schedule_planner.view_month', 'Mes') },
    { value: 'week' as const, label: t('schedule_planner.view_week', 'Setmana') },
    { value: 'year' as const, label: t('schedule_planner.view_year', 'Any') },
  ]

  const dataOptions = [
    { value: 'planned' as const, label: t('schedule_planner.data_planned', 'Planificat') },
    { value: 'actual' as const, label: t('schedule_planner.data_actual', 'Fitxatge real') },
    { value: 'compare' as const, label: t('schedule_planner.data_compare', 'Comparar') },
  ]

  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className="inline-flex items-center rounded-lg border bg-background">
        <Button type="button" variant="ghost" size="icon" className="h-8 w-8 rounded-r-none" onClick={onPrev}>
          <ChevronLeft className="h-4 w-4" />
        </Button>
        <div className="border-x px-1">
          <SchedulePeriodPicker
            anchor={anchor}
            viewMode={viewMode}
            months={months}
            periodLabel={periodLabel}
            isRefreshing={isRefreshing}
            onApply={onAnchorChange}
          />
        </div>
        <Button type="button" variant="ghost" size="icon" className="h-8 w-8 rounded-l-none" onClick={onNext}>
          <ChevronRight className="h-4 w-4" />
        </Button>
      </div>

      <Button type="button" variant="outline" size="sm" className="h-8" onClick={onToday}>
        {t('schedule_planner.today', 'Avui')}
      </Button>

      <PillToggleGroup value={viewMode} options={viewOptions} onChange={onViewModeChange} />

      {viewMode === 'week' && (
        <PillToggleGroup value={dataMode} options={dataOptions} onChange={onDataModeChange} />
      )}
    </div>
  )
}
