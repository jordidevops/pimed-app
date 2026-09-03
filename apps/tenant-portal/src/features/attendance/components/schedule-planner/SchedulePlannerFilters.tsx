import { useTranslation } from 'react-i18next'
import { ChevronDown, Search, X } from 'lucide-react'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { cn } from '@/lib/utils'
import type { PlannerFilters, PlannerGroupBy } from '../../api/schedulePlannerFilters'
import type { CalendarGroup } from '../../api/useLaborCalendar'

interface DepartmentOption {
  id: string
  name: string
}

interface SchedulePlannerFiltersProps {
  filters: PlannerFilters
  onChange: (patch: Partial<PlannerFilters>) => void
  departments: DepartmentOption[]
  calendarGroups: CalendarGroup[]
  showDiscrepancyFilter?: boolean
}

export function SchedulePlannerFilters({
  filters,
  onChange,
  departments,
  calendarGroups,
  showDiscrepancyFilter = false,
}: SchedulePlannerFiltersProps) {
  const { t } = useTranslation('attendance')

  const hasActive =
    !!filters.search.trim()
    || !!filters.departmentId
    || !!filters.calendarGroupId
    || filters.discrepancyOnly
    || filters.sortBy !== 'name'
    || filters.groupBy !== 'none'

  const groupOptions: { value: PlannerGroupBy; label: string }[] = [
    { value: 'none', label: t('schedule_planner.group_none', 'Sense agrupació') },
    { value: 'department', label: t('schedule_planner.group_department', 'Departament') },
    { value: 'calendar_group', label: t('schedule_planner.group_calendar', 'Grup calendari') },
  ]

  const sortOptions = [
    { value: 'name' as const, label: t('schedule_planner.sort_name', 'Nom') },
    { value: 'planned_hours' as const, label: t('schedule_planner.sort_planned_hours', 'Hores') },
  ]

  const selectedDepartment = departments.find((d) => d.id === filters.departmentId)
  const selectedGroup = calendarGroups.find((g) => g.id === filters.calendarGroupId)

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-[160px] flex-1 sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-8 pl-8 text-xs"
            placeholder={t('schedule_planner.filter_search', 'Cerca empleat…')}
            value={filters.search}
            onChange={(e) => onChange({ search: e.target.value })}
          />
        </div>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button type="button" variant="outline" size="sm" className="h-8 gap-1 text-xs">
              {selectedDepartment?.name ?? t('schedule_planner.filter_all_departments', 'Tots els departaments')}
              <ChevronDown className="h-3.5 w-3.5 opacity-60" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="max-h-64 overflow-y-auto">
            <DropdownMenuItem onSelect={() => onChange({ departmentId: null })}>
              {t('schedule_planner.filter_all_departments', 'Tots els departaments')}
            </DropdownMenuItem>
            {departments.map((d) => (
              <DropdownMenuItem key={d.id} onSelect={() => onChange({ departmentId: d.id })}>
                {d.name}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>

        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button type="button" variant="outline" size="sm" className="h-8 gap-1 text-xs">
              {selectedGroup?.name ?? t('schedule_planner.filter_all_groups', 'Tots els grups')}
              <ChevronDown className="h-3.5 w-3.5 opacity-60" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="max-h-64 overflow-y-auto">
            <DropdownMenuItem onSelect={() => onChange({ calendarGroupId: null })}>
              {t('schedule_planner.filter_all_groups', 'Tots els grups')}
            </DropdownMenuItem>
            {calendarGroups.map((g) => (
              <DropdownMenuItem key={g.id} onSelect={() => onChange({ calendarGroupId: g.id ?? null })}>
                {g.name}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>

        <PillToggleGroup value={filters.sortBy} options={sortOptions} onChange={(sortBy) => onChange({ sortBy })} />

        {showDiscrepancyFilter && (
          <div className="flex items-center gap-2">
            <Checkbox
              id="planner-discrepancy-only"
              checked={filters.discrepancyOnly}
              onCheckedChange={(checked) => onChange({ discrepancyOnly: checked === true })}
            />
            <Label htmlFor="planner-discrepancy-only" className="cursor-pointer text-xs font-normal">
              {t('schedule_planner.filter_discrepancy_only', 'Només discrepàncies')}
            </Label>
          </div>
        )}

        {hasActive && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-8 gap-1 text-xs"
            onClick={() => onChange({
              search: '',
              departmentId: null,
              calendarGroupId: null,
              discrepancyOnly: false,
              sortBy: 'name',
              groupBy: 'none',
            })}
          >
            <X className="h-3.5 w-3.5" />
            {t('schedule_planner.filter_clear', 'Netejar')}
          </Button>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-muted-foreground">
          {t('schedule_planner.group_by_label', 'Agrupar')}:
        </span>
        {groupOptions.map((opt) => (
          <Badge
            key={opt.value}
            variant={filters.groupBy === opt.value ? 'default' : 'outline'}
            className={cn(
              'cursor-pointer select-none',
              filters.groupBy !== opt.value && 'hover:bg-accent',
            )}
            onClick={() => onChange({ groupBy: opt.value })}
          >
            {opt.label}
          </Badge>
        ))}
      </div>
    </div>
  )
}
