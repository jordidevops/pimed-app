import { LayoutGrid, List, Rows3 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import type { ListDensity } from '@/hooks/useListDensity'
import type { ListViewMode } from '@/hooks/useListViewMode'

type ListViewToggleProps = {
  mode: ListViewMode
  onModeChange: (mode: ListViewMode) => void
  density?: ListDensity
  onDensityChange?: (density: ListDensity) => void
  /** Hide density when not in table mode or when unsupported. */
  showDensity?: boolean
  disabled?: boolean
  className?: string
}

export function ListViewToggle({
  mode,
  onModeChange,
  density,
  onDensityChange,
  showDensity = true,
  disabled = false,
  className,
}: ListViewToggleProps) {
  const { t } = useTranslation('common')

  return (
    <div className={cn('inline-flex flex-wrap items-center gap-1', className)}>
      <div
        className="inline-flex rounded-lg border border-border bg-muted/40 p-0.5"
        role="group"
        aria-label={t('list.view_label', 'Vista')}
      >
        <Button
          type="button"
          size="sm"
          variant={mode === 'table' ? 'default' : 'ghost'}
          className="h-7 gap-1.5 px-2.5 text-xs"
          disabled={disabled}
          aria-pressed={mode === 'table'}
          onClick={() => onModeChange('table')}
        >
          <List className="h-3.5 w-3.5" aria-hidden />
          {t('list.view_table', 'Taula')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant={mode === 'cards' ? 'default' : 'ghost'}
          className="h-7 gap-1.5 px-2.5 text-xs"
          disabled={disabled}
          aria-pressed={mode === 'cards'}
          onClick={() => onModeChange('cards')}
        >
          <LayoutGrid className="h-3.5 w-3.5" aria-hidden />
          {t('list.view_cards', 'Targetes')}
        </Button>
      </div>

      {showDensity && mode === 'table' && density && onDensityChange ? (
        <div
          className="inline-flex rounded-lg border border-border bg-muted/40 p-0.5"
          role="group"
          aria-label={t('list.density_label', 'Densitat')}
        >
          <Button
            type="button"
            size="sm"
            variant={density === 'compact' ? 'default' : 'ghost'}
            className="h-7 gap-1.5 px-2.5 text-xs"
            disabled={disabled}
            aria-pressed={density === 'compact'}
            onClick={() => onDensityChange('compact')}
          >
            <Rows3 className="h-3.5 w-3.5" aria-hidden />
            {t('list.density_compact', 'Compacta')}
          </Button>
          <Button
            type="button"
            size="sm"
            variant={density === 'comfortable' ? 'default' : 'ghost'}
            className="h-7 px-2.5 text-xs"
            disabled={disabled}
            aria-pressed={density === 'comfortable'}
            onClick={() => onDensityChange('comfortable')}
          >
            {t('list.density_comfortable', 'Còmoda')}
          </Button>
        </div>
      ) : null}
    </div>
  )
}
