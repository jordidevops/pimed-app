import { ChevronRight, Edit, PlusCircle, PowerOff } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import type { Department } from '../api/departmentsService'

interface DepartmentRowProps {
  department: Department
  childrenCount: number
  onDrillIn: (dept: Department) => void
  onEdit: (dept: Department) => void
  onAddChild: (dept: Department) => void
  onToggleActive: (dept: Department) => void
}

export function DepartmentRow({
  department,
  childrenCount,
  onDrillIn,
  onEdit,
  onAddChild,
  onToggleActive,
}: DepartmentRowProps) {
  const { t } = useTranslation('departments')
  const name = department.name ?? '—'
  const isActive = department.is_active !== false

  return (
    <div className="flex items-center gap-3 px-4 py-3 rounded-xl border border-border bg-card hover:bg-accent/30 transition-colors">
      {/* Monogram */}
      <div className="h-9 w-9 rounded-lg bg-primary/10 flex items-center justify-center shrink-0 select-none" aria-hidden>
        <span className="text-primary font-bold text-xs">
          {department.code?.slice(0, 3).toUpperCase() ?? name.slice(0, 2).toUpperCase()}
        </span>
      </div>

      {/* Name + badges */}
      <div className="flex-1 min-w-0">
        <button
          type="button"
          onClick={() => onDrillIn(department)}
          className="text-sm font-semibold text-foreground truncate text-left hover:underline"
        >
          {name}
        </button>
        <div className="flex flex-wrap items-center gap-1.5 mt-0.5">
          {department.code && (
            <Badge variant="outline" className="text-[10px] h-4 px-1.5">
              {department.code}
            </Badge>
          )}
          {!isActive && (
            <Badge variant="secondary" className="text-[10px] h-4 px-1.5">
              {t('departments.badge.inactive', 'Inactiu')}
            </Badge>
          )}
          {childrenCount > 0 && (
            <span className="text-[11px] text-muted-foreground">
              {t('departments.children_count', '{{count}} subdepartaments', { count: childrenCount })}
            </span>
          )}
        </div>
      </div>

      {/* Actions */}
      <div className="flex items-center gap-0.5 shrink-0">
        <Button
          variant="ghost"
          size="sm"
          className="h-7 w-7 p-0 text-muted-foreground hover:text-foreground"
          onClick={() => onEdit(department)}
          title={t('departments.actions.edit', 'Editar')}
        >
          <Edit className="h-3.5 w-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="sm"
          className="h-7 w-7 p-0 text-muted-foreground hover:text-foreground"
          onClick={() => onAddChild(department)}
          title={t('departments.actions.add_child', 'Afegir subdepartament')}
        >
          <PlusCircle className="h-3.5 w-3.5" />
        </Button>
        <Button
          variant="ghost"
          size="sm"
          className={`h-7 w-7 p-0 ${
            isActive
              ? 'text-muted-foreground hover:text-destructive'
              : 'text-emerald-600 hover:text-emerald-700'
          }`}
          onClick={() => onToggleActive(department)}
          title={
            isActive
              ? t('departments.actions.deactivate', 'Desactivar')
              : t('departments.actions.reactivate', 'Reactivar')
          }
        >
          <PowerOff className="h-3.5 w-3.5" />
        </Button>
        {childrenCount > 0 && (
          <Button
            variant="ghost"
            size="sm"
            className="h-7 w-7 p-0 text-muted-foreground"
            onClick={() => onDrillIn(department)}
            title={t('departments.actions.view_children', 'Veure subdepartaments')}
          >
            <ChevronRight className="h-4 w-4" />
          </Button>
        )}
      </div>
    </div>
  )
}
