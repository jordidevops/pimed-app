import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { CheckSquare, AlertCircle } from 'lucide-react'
import { getMyOpenTasks, type EntityTimelineType } from '../api/timelineService'
import { renderMentionContent } from '../utils/renderMentionContent'

const ENTITY_TYPE_LABELS: Record<EntityTimelineType, string> = {
  employee: 'Empleat',
  contact: 'Contacte',
  project: 'Projecte',
  document: 'Document',
}

interface OpenTasksWidgetProps {
  tenantId: string | null | undefined
}

export function OpenTasksWidget({ tenantId }: OpenTasksWidgetProps) {
  const { t } = useTranslation(['activity', 'common'])

  const { data, isLoading, isError } = useQuery({
    queryKey: ['my-open-tasks', tenantId],
    queryFn: () => getMyOpenTasks({ limit: 8 }),
    enabled: !!tenantId,
  })

  if (!tenantId) return null

  const items = data?.items ?? []
  const isManagerView = data?.page.is_manager_view ?? false

  return (
    <section className="bg-card rounded-2xl border border-border p-5 shadow-sm space-y-3">
      <div className="flex items-center gap-2">
        <CheckSquare className="h-5 w-5 text-amber-600" aria-hidden />
        <h3 className="text-lg font-semibold text-foreground">
          {t('activity:open_tasks.title', 'Tasques obertes')}
        </h3>
        {!isLoading && items.length > 0 && (
          <span className="text-xs font-medium bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200 px-2 py-0.5 rounded-full">
            {items.length}
            {data?.page.has_more ? '+' : ''}
          </span>
        )}
      </div>

      {isManagerView && (
        <p className="text-xs text-muted-foreground">
          {t('activity:open_tasks.manager_hint', 'Vista de totes les tasques pendents del tenant.')}
        </p>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('common:dashboard.loading', 'Carregant...')}
        </p>
      ) : isError ? (
        <p className="text-sm text-destructive">
          {t('activity:open_tasks.error', 'Error en carregar les tasques.')}
        </p>
      ) : items.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('activity:open_tasks.empty', 'Cap tasca pendent.')}
        </p>
      ) : (
        <ul className="space-y-2">
          {items.map((task) => (
            <li key={task.id}>
              <Link
                to={task.deep_link}
                className="block rounded-lg border border-border hover:border-primary/40 hover:bg-muted/30 px-3 py-2.5 transition-colors"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="text-xs text-muted-foreground truncate">
                      {ENTITY_TYPE_LABELS[task.entity_type] ?? task.entity_type}
                      {' · '}
                      <span className="font-medium text-foreground">{task.entity_label}</span>
                    </p>
                    <p className="text-sm mt-0.5 line-clamp-2">
                      {renderMentionContent(task.content_preview)}
                    </p>
                  </div>
                  {task.is_overdue && (
                    <span
                      className="shrink-0 inline-flex items-center gap-1 text-xs text-destructive"
                      title={t('activity:open_tasks.overdue', 'Vençuda')}
                    >
                      <AlertCircle className="h-3.5 w-3.5" aria-hidden />
                    </span>
                  )}
                </div>
                <p className="text-xs text-muted-foreground mt-1.5">
                  {task.author?.full_name ?? '?'}
                  {' · '}
                  {new Date(task.created_at).toLocaleDateString('ca-ES', {
                    day: 'numeric',
                    month: 'short',
                  })}
                  {task.due_date && (
                    <>
                      {' · '}
                      {t('activity:open_tasks.due', 'Venciment')}:{' '}
                      {new Date(task.due_date).toLocaleDateString('ca-ES')}
                    </>
                  )}
                </p>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
