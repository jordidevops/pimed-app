import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import type { EmployeeViewMode } from '../../hooks/useDashboardLayout'

interface DashboardEmployeeViewToggleProps {
  value: EmployeeViewMode
  onChange: (view: EmployeeViewMode) => void
}

export function DashboardEmployeeViewToggle({ value, onChange }: DashboardEmployeeViewToggleProps) {
  const { t } = useTranslation('attendance')

  return (
    <div className="inline-flex overflow-hidden rounded-lg border">
      <Button
        type="button"
        size="sm"
        variant={value === 'cards' ? 'default' : 'ghost'}
        className="h-8 rounded-none px-3 text-xs"
        onClick={() => onChange('cards')}
      >
        {t('dashboard.view_cards', 'Tarjetes')}
      </Button>
      <Button
        type="button"
        size="sm"
        variant={value === 'table' ? 'default' : 'ghost'}
        className="h-8 rounded-none px-3 text-xs"
        onClick={() => onChange('table')}
      >
        {t('dashboard.view_table', 'Taula')}
      </Button>
    </div>
  )
}
