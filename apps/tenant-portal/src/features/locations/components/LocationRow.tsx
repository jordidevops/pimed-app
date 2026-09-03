import { ChevronRight, Edit, Layers, LayoutGrid, Package, PlusCircle, PowerOff, Square, Sun } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { Location } from '../api/locationsService'
import type { LocationType, LocationStatus } from '../schemas/locationSchema'

const TYPE_ICON: Record<LocationType, React.ReactNode> = {
  floor: <Layers className="h-4 w-4" aria-hidden />,
  room: <Square className="h-4 w-4" aria-hidden />,
  zone: <LayoutGrid className="h-4 w-4" aria-hidden />,
  outdoor: <Sun className="h-4 w-4" aria-hidden />,
  other: <Package className="h-4 w-4" aria-hidden />,
}

const STATUS_CLASS: Record<LocationStatus, string> = {
  active: 'bg-emerald-100 text-emerald-700 border-emerald-200',
  maintenance: 'bg-amber-100 text-amber-700 border-amber-200',
  inactive: 'bg-muted text-muted-foreground border-border',
}

const NEXT_STATUS: Record<LocationStatus, LocationStatus> = {
  active: 'inactive',
  maintenance: 'active',
  inactive: 'active',
}

interface LocationRowProps {
  location: Location
  childrenCount: number
  onDrillIn: (loc: Location) => void
  onEdit: (loc: Location) => void
  onAddChild: (loc: Location) => void
  onToggleStatus: (loc: Location) => void
  canWrite: boolean
}

export function LocationRow({
  location,
  childrenCount,
  onDrillIn,
  onEdit,
  onAddChild,
  onToggleStatus,
  canWrite,
}: LocationRowProps) {
  const { t } = useTranslation('locations')
  const name = location.name ?? '—'
  const locType = (location.type ?? 'other') as LocationType
  const locStatus = (location.status ?? 'active') as LocationStatus

  return (
    <div className="flex items-center gap-3 px-4 py-3 rounded-xl border border-border bg-card hover:bg-accent/30 transition-colors">
      {/* Type icon */}
      <div className="h-9 w-9 rounded-lg bg-primary/10 flex items-center justify-center shrink-0 text-primary select-none">
        {TYPE_ICON[locType]}
      </div>

      {/* Name + badges */}
      <div className="flex-1 min-w-0">
        <button
          type="button"
          onClick={() => onDrillIn(location)}
          className="text-sm font-semibold text-foreground truncate text-left hover:underline"
        >
          {name}
        </button>
        <div className="flex flex-wrap items-center gap-1.5 mt-0.5">
          <Badge
            variant="outline"
            className={`text-[10px] h-4 px-1.5 ${STATUS_CLASS[locStatus]}`}
          >
            {t(`locations.status.${locStatus}`, locStatus)}
          </Badge>
          <Badge variant="outline" className="text-[10px] h-4 px-1.5 capitalize">
            {t(`locations.type.${locType}`, locType)}
          </Badge>
          {childrenCount > 0 && (
            <span className="text-[11px] text-muted-foreground">
              {t('locations.children_count', '{{count}} sububicacions', { count: childrenCount })}
            </span>
          )}
        </div>
      </div>

      {/* Actions */}
      <div className="flex items-center gap-0.5 shrink-0">
        {canWrite && (
          <>
            <Button
              variant="ghost"
              size="sm"
              className="h-7 w-7 p-0 text-muted-foreground hover:text-foreground"
              onClick={() => onEdit(location)}
              title={t('locations.actions.edit', 'Editar')}
            >
              <Edit className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className="h-7 w-7 p-0 text-muted-foreground hover:text-foreground"
              onClick={() => onAddChild(location)}
              title={t('locations.actions.add_child', 'Afegir sububicació')}
            >
              <PlusCircle className="h-3.5 w-3.5" />
            </Button>
            <Button
              variant="ghost"
              size="sm"
              className={`h-7 w-7 p-0 ${
                locStatus === 'active'
                  ? 'text-muted-foreground hover:text-foreground'
                  : 'text-emerald-600 hover:text-emerald-700'
              }`}
              onClick={() => onToggleStatus(location)}
              title={t(
                `locations.actions.set_${NEXT_STATUS[locStatus]}`,
                `Marcar com a ${NEXT_STATUS[locStatus]}`,
              )}
            >
              <PowerOff className="h-3.5 w-3.5" />
            </Button>
          </>
        )}
        <Button
          variant="ghost"
          size="sm"
          className="h-7 w-7 p-0 text-muted-foreground hover:text-foreground"
          onClick={() => onDrillIn(location)}
          title={t('locations.actions.drill_in', 'Veure sububicacions')}
        >
          <ChevronRight className="h-3.5 w-3.5" />
        </Button>
      </div>
    </div>
  )
}
