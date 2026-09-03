import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LayoutGrid, Settings2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover'
import {
  WIDGET_LABELS,
  type CalendarMonthPanels,
  type CalendarScope,
  type DashboardWidgetId,
} from '../../hooks/useDashboardLayout'

interface DashboardSettingsProps {
  calendarScope: CalendarScope
  calendarMonthPanels: CalendarMonthPanels
  widgets: Record<DashboardWidgetId, boolean>
  onCalendarScopeChange: (scope: CalendarScope) => void
  onCalendarMonthPanelsChange: (panels: CalendarMonthPanels) => void
  onToggleWidget: (id: DashboardWidgetId) => void
  onReset: () => void
}

const ALL_WIDGETS: DashboardWidgetId[] = [
  'stats',
  'coverage_gaps',
  'station_fleet',
  'incidents',
  'pending_absences',
  'legal_risk',
  'employees',
  'calendar',
  'map',
]

export function DashboardSettings({
  calendarScope,
  calendarMonthPanels,
  widgets,
  onCalendarScopeChange,
  onCalendarMonthPanelsChange,
  onToggleWidget,
  onReset,
}: DashboardSettingsProps) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  const scopeOptions = [
    { value: 'site' as const, label: t('dashboard.calendar_site', 'Local') },
    { value: 'tenant' as const, label: t('dashboard.calendar_tenant', 'Empresa') },
  ]

  const panelOptions: { key: keyof CalendarMonthPanels; label: string }[] = [
    { key: 'prev', label: t('dashboard.calendar_panel_prev', 'Mes anterior') },
    { key: 'current', label: t('dashboard.calendar_panel_current', 'Mes actual') },
    { key: 'next', label: t('dashboard.calendar_panel_next', 'Mes següent') },
  ]

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" size="sm">
          <Settings2 className="mr-1.5 h-4 w-4" />
          {t('dashboard.configure', 'Configurar panell')}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-72 space-y-4" align="end">
        <div>
          <p className="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            <LayoutGrid className="h-3.5 w-3.5" />
            {t('dashboard.widgets', 'Widgets')}
          </p>
          <div className="space-y-2">
            {ALL_WIDGETS.map((id) => (
              <div key={id} className="flex items-center gap-2">
                <Checkbox
                  id={`widget-${id}`}
                  checked={widgets[id]}
                  onCheckedChange={() => onToggleWidget(id)}
                />
                <Label htmlFor={`widget-${id}`} className="cursor-pointer text-sm font-normal">
                  {t(WIDGET_LABELS[id], id)}
                </Label>
              </div>
            ))}
          </div>
        </div>
        <div>
          <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('dashboard.calendar_scope', 'Calendari')}
          </p>
          <PillToggleGroup
            value={calendarScope}
            options={scopeOptions}
            onChange={onCalendarScopeChange}
            className="w-full"
          />
        </div>
        <div>
          <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('dashboard.calendar_month_panels', 'Mesos visibles')}
          </p>
          <div className="space-y-2">
            {panelOptions.map(({ key, label }) => (
              <div key={key} className="flex items-center gap-2">
                <Checkbox
                  id={`cal-panel-${key}`}
                  checked={calendarMonthPanels[key]}
                  onCheckedChange={(checked) => {
                    onCalendarMonthPanelsChange({
                      ...calendarMonthPanels,
                      [key]: checked === true,
                    })
                  }}
                />
                <Label htmlFor={`cal-panel-${key}`} className="cursor-pointer text-sm font-normal">
                  {label}
                </Label>
              </div>
            ))}
          </div>
        </div>
        <Button type="button" variant="ghost" size="sm" className="w-full" onClick={onReset}>
          {t('dashboard.reset_layout', 'Restaurar per defecte')}
        </Button>
      </PopoverContent>
    </Popover>
  )
}
