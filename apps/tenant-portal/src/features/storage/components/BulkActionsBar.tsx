import { useTranslation } from 'react-i18next'
import { useExplorer, type ExplorerView } from '../contexts/ExplorerContext'

interface BulkActionsBarProps {
  view: ExplorerView
  onStar: () => void
  starMode: 'star' | 'unstar'
  onTrash: () => void
  onRestore: () => void
  onDelete: () => void
  isPending: boolean
}

export function BulkActionsBar({ view, onStar, starMode, onTrash, onRestore, onDelete, isPending }: BulkActionsBarProps) {
  const { t } = useTranslation('storage')
  const { state, clearSelection } = useExplorer()

  const count = state.selectedIds.size
  if (count === 0) return null

  return (
    <div className="flex items-center gap-3 px-4 py-2 bg-indigo-50 border-t border-indigo-100 shrink-0">
      <span className="text-sm font-medium text-indigo-700">
        {t('storage.explorer.selected_count', '{{count}} seleccionats', { count })}
      </span>

      <div className="flex items-center gap-1.5 ml-auto">
        {/* Star — only in files & search view */}
        {(view === 'files' || view === 'search' || view === 'starred') && (
          <button
            type="button"
            onClick={onStar}
            disabled={isPending}
            className="flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium text-amber-700 bg-amber-50 border border-amber-200 hover:bg-amber-100 transition disabled:opacity-50"
          >
            {starMode === 'unstar' ? '✖️' : '⭐'}{' '}
            {starMode === 'unstar'
              ? t('storage.explorer.action_unstar', 'Treure destacat')
              : t('storage.explorer.action_star', 'Destacar')}
          </button>
        )}

        {/* Trash — only in files, starred, search */}
        {view !== 'trash' && (
          <button
            type="button"
            onClick={onTrash}
            disabled={isPending}
            className="flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium text-red-700 bg-red-50 border border-red-200 hover:bg-red-100 transition disabled:opacity-50"
          >
            🗑️ {t('storage.explorer.action_trash', 'Llençar')}
          </button>
        )}

        {/* Restore — only in trash */}
        {view === 'trash' && (
          <button
            type="button"
            onClick={onRestore}
            disabled={isPending}
            className="flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium text-green-700 bg-green-50 border border-green-200 hover:bg-green-100 transition disabled:opacity-50"
          >
            ♻️ {t('storage.explorer.action_restore', 'Restaurar')}
          </button>
        )}

        {/* Permanent delete — only in trash */}
        {view === 'trash' && (
          <button
            type="button"
            onClick={onDelete}
            disabled={isPending}
            className="flex items-center gap-1 px-2.5 py-1 rounded-md text-xs font-medium text-red-700 bg-red-50 border border-red-200 hover:bg-red-100 transition disabled:opacity-50"
          >
            ❌ {t('storage.explorer.action_delete_permanent', 'Eliminar permanentment')}
          </button>
        )}

        {/* Clear selection */}
        <button
          type="button"
          onClick={clearSelection}
          className="px-2.5 py-1 rounded-md text-xs font-medium text-muted-foreground border border-border hover:bg-accent transition"
        >
          {t('storage.explorer.action_deselect', 'Deseleccionar')}
        </button>
      </div>
    </div>
  )
}
