import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Search, SlidersHorizontal } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { cn } from '@/lib/utils'
import {
  type DatePreset,
  type TimelineFilterState,
  DEFAULT_TIMELINE_FILTERS,
  hasActiveTimelineFilters,
} from '../utils/timelineFilters'

const DATE_PRESETS: DatePreset[] = ['all', '7d', '30d', '90d', 'custom']

interface TimelineFiltersProps {
  filters: TimelineFilterState
  onChange: (next: TimelineFilterState) => void
}

export function TimelineFilters({ filters, onChange }: TimelineFiltersProps) {
  const { t } = useTranslation('activity')
  const [expanded, setExpanded] = useState(false)

  const set = (patch: Partial<TimelineFilterState>) => onChange({ ...filters, ...patch })

  const handlePreset = (preset: DatePreset) => {
    if (preset === 'custom') {
      set({ datePreset: 'custom' })
      return
    }
    set({ datePreset: preset, dateFrom: '', dateTo: '' })
  }

  const showCustomDates = filters.datePreset === 'custom'
  const filtersActive = hasActiveTimelineFilters(filters)

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <div className="relative min-w-0 flex-1 max-w-md">
          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground pointer-events-none" />
          <Input
            type="search"
            value={filters.search}
            onChange={(e) => set({ search: e.target.value })}
            placeholder={t('timeline.search_placeholder', 'Cerca en comentaris...')}
            className="pl-8 h-8 text-sm"
            aria-label={t('timeline.search_label', 'Cerca en comentaris')}
          />
        </div>
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="h-8 w-8 shrink-0 sm:hidden"
          aria-expanded={expanded}
          aria-label={t('timeline.filter_toggle', 'Filtres')}
          onClick={() => setExpanded((v) => !v)}
        >
          <SlidersHorizontal className="h-3.5 w-3.5" />
        </Button>
        {filtersActive && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-8 text-xs shrink-0 sm:hidden"
            onClick={() => onChange(DEFAULT_TIMELINE_FILTERS)}
          >
            {t('timeline.filter_clear', 'Esborrar filtres')}
          </Button>
        )}
      </div>

      <div className={cn('space-y-3', !expanded && 'hidden sm:block')}>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex items-center gap-1 rounded-lg border bg-muted/40 p-1">
            {DATE_PRESETS.map((preset) => (
              <button
                key={preset}
                type="button"
                onClick={() => handlePreset(preset)}
                className={`rounded px-2.5 py-1 text-xs font-medium transition-colors ${
                  filters.datePreset === preset
                    ? 'bg-background shadow-sm text-foreground'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                {preset === 'all'
                  ? t('timeline.filter_range_all', 'Tot')
                  : preset === 'custom'
                    ? t('timeline.filter_range_custom', 'Personalitzat')
                    : t('timeline.filter_range_days', 'Darrers {{n}} dies', {
                        n: preset === '7d' ? 7 : preset === '30d' ? 30 : 90,
                      })}
              </button>
            ))}
          </div>

          {showCustomDates && (
            <div className="flex flex-wrap items-center gap-2">
              <input
                type="date"
                title={t('timeline.filter_date_from', 'Des de')}
                value={filters.dateFrom}
                onChange={(e) => set({ dateFrom: e.target.value, datePreset: 'custom' })}
                className="h-8 text-sm border border-input rounded-md px-2 bg-background"
              />
              <span className="text-muted-foreground text-xs">—</span>
              <input
                type="date"
                title={t('timeline.filter_date_to', 'Fins a')}
                value={filters.dateTo}
                min={filters.dateFrom || undefined}
                onChange={(e) => set({ dateTo: e.target.value, datePreset: 'custom' })}
                className="h-8 text-sm border border-input rounded-md px-2 bg-background"
              />
            </div>
          )}
        </div>

        <div className="grid gap-2 sm:flex sm:flex-wrap sm:items-center sm:gap-3 text-sm">
          <label className="flex items-center gap-2 cursor-pointer w-full sm:w-auto">
            <input
              type="checkbox"
              checked={filters.includeAudit}
              onChange={(e) =>
                set({
                  includeAudit: e.target.checked,
                  includeBackground: e.target.checked ? filters.includeBackground : false,
                })
              }
            />
            {t('timeline.filter_audit', 'Events del sistema')}
          </label>
          {filters.includeAudit && (
            <label className="flex items-center gap-2 cursor-pointer w-full sm:w-auto">
              <input
                type="checkbox"
                checked={filters.includeBackground}
                onChange={(e) => set({ includeBackground: e.target.checked })}
              />
              {t('timeline.filter_background', 'Events en segon pla')}
            </label>
          )}
          <label className="flex items-center gap-2 cursor-pointer w-full sm:w-auto">
            <input
              type="checkbox"
              checked={filters.tasksOnly}
              onChange={(e) =>
                set({
                  tasksOnly: e.target.checked,
                  openTasksOnly: e.target.checked ? false : filters.openTasksOnly,
                })
              }
            />
            {t('timeline.filter_tasks', 'Només tasques')}
          </label>
          <label className="flex items-center gap-2 cursor-pointer w-full sm:w-auto">
            <input
              type="checkbox"
              checked={filters.openTasksOnly}
              onChange={(e) =>
                set({
                  openTasksOnly: e.target.checked,
                  tasksOnly: e.target.checked ? false : filters.tasksOnly,
                  includeAudit: e.target.checked ? false : filters.includeAudit,
                })
              }
            />
            {t('timeline.filter_open_tasks', 'Només tasques obertes')}
          </label>

          {filtersActive && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="h-7 text-xs hidden sm:inline-flex"
              onClick={() => onChange(DEFAULT_TIMELINE_FILTERS)}
            >
              {t('timeline.filter_clear', 'Esborrar filtres')}
            </Button>
          )}
        </div>
      </div>
    </div>
  )
}
