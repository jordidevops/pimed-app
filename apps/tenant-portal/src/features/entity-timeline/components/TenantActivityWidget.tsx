import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useInfiniteQuery } from '@tanstack/react-query'
import { Activity, CheckSquare } from 'lucide-react'
import {
  getTenantTimelineActivity,
  type EntityTimelineType,
  type TenantActivityItem,
} from '../api/timelineService'
import { formatAuditMessage } from '../registry/timelineAuditRegistry'
import { renderMentionContent } from '../utils/renderMentionContent'

const ENTITY_TYPE_LABELS: Record<EntityTimelineType, string> = {
  employee: 'Empleat',
  contact: 'Contacte',
  project: 'Projecte',
  document: 'Document',
}

function formatItemTime(iso: string, locale: string): string {
  return new Date(iso).toLocaleTimeString(locale, {
    hour: '2-digit',
    minute: '2-digit',
  })
}

function ActivityItemSummary({ item }: { item: TenantActivityItem }) {
  const { t } = useTranslation('activity')

  if (item.kind === 'audit_event') {
    const actorName = item.actor?.full_name ?? t('timeline.system', 'Sistema')
    const text = formatAuditMessage(
      t,
      item.action ?? '',
      item.message_vars ?? {},
      actorName,
    )
    return (
      <p className="text-sm mt-0.5 line-clamp-2 text-muted-foreground">
        {text}
      </p>
    )
  }

  if (item.deleted) {
    return (
      <p className="text-sm mt-0.5 italic text-muted-foreground">
        {t('timeline.comment_deleted', 'Comentari eliminat')}
      </p>
    )
  }

  return (
    <p className="text-sm mt-0.5 line-clamp-2">
      {item.is_task && (
        <CheckSquare
          className="inline h-3.5 w-3.5 mr-1 text-amber-600 align-text-bottom"
          aria-hidden
        />
      )}
      {renderMentionContent(item.content ?? '')}
    </p>
  )
}

interface TenantActivityWidgetProps {
  tenantId: string | null | undefined
}

export function TenantActivityWidget({ tenantId }: TenantActivityWidgetProps) {
  const { t, i18n } = useTranslation(['activity', 'common'])
  const locale = i18n.resolvedLanguage?.startsWith('ca')
    ? 'ca-ES'
    : i18n.resolvedLanguage?.startsWith('es')
      ? 'es-ES'
      : 'en-US'

  const {
    data,
    isLoading,
    isError,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
  } = useInfiniteQuery({
    queryKey: ['tenant-timeline-activity', tenantId],
    queryFn: ({ pageParam }) =>
      getTenantTimelineActivity({
        limit: 25,
        cursor: pageParam?.cursor,
        cursorId: pageParam?.cursorId,
      }),
    initialPageParam: {
      cursor: null as string | null,
      cursorId: null as string | null,
    },
    getNextPageParam: (last) =>
      last.page.has_more
        ? { cursor: last.page.next_cursor, cursorId: last.page.next_cursor_id }
        : undefined,
    enabled: !!tenantId,
  })

  if (!tenantId) return null

  const items = data?.pages.flatMap((p) => p.items) ?? []
  const since = data?.pages[0]?.page.since

  return (
    <section className="bg-card rounded-2xl border border-border p-5 shadow-sm space-y-3">
      <div className="flex items-center gap-2">
        <Activity className="h-5 w-5 text-primary" aria-hidden />
        <h3 className="text-lg font-semibold text-foreground">
          {t('activity:tenant_activity.title', 'Activitat avui')}
        </h3>
        {!isLoading && items.length > 0 && (
          <span className="text-xs font-medium bg-primary/10 text-primary px-2 py-0.5 rounded-full">
            {items.length}
            {hasNextPage ? '+' : ''}
          </span>
        )}
      </div>

      {since && (
        <p className="text-xs text-muted-foreground">
          {t('activity:tenant_activity.since', 'Des de {{time}}', {
            time: new Date(since).toLocaleString(locale, {
              day: 'numeric',
              month: 'short',
              hour: '2-digit',
              minute: '2-digit',
            }),
          })}
        </p>
      )}

      {isLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('common:dashboard.loading', 'Carregant...')}
        </p>
      ) : isError ? (
        <p className="text-sm text-destructive">
          {t('activity:tenant_activity.error', "Error en carregar l'activitat.")}
        </p>
      ) : items.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('activity:tenant_activity.empty', 'Cap activitat avui.')}
        </p>
      ) : (
        <>
          <ul className="space-y-2">
            {items.map((item) => {
              const actorName =
                item.kind === 'comment'
                  ? item.author?.full_name
                  : item.actor?.full_name

              return (
                <li key={`${item.kind}-${item.id}`}>
                  <Link
                    to={item.deep_link}
                    className="block rounded-lg border border-border hover:border-primary/40 hover:bg-muted/30 px-3 py-2.5 transition-colors"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <p className="text-xs text-muted-foreground truncate">
                          {ENTITY_TYPE_LABELS[item.entity_type] ?? item.entity_type}
                          {' · '}
                          <span className="font-medium text-foreground">
                            {item.entity_label}
                          </span>
                        </p>
                        <ActivityItemSummary item={item} />
                      </div>
                      <time
                        className="shrink-0 text-xs text-muted-foreground tabular-nums"
                        dateTime={item.created_at}
                      >
                        {formatItemTime(item.created_at, locale)}
                      </time>
                    </div>
                    {actorName && (
                      <p className="text-xs text-muted-foreground mt-1.5">
                        {actorName}
                      </p>
                    )}
                  </Link>
                </li>
              )
            })}
          </ul>

          {hasNextPage && (
            <button
              type="button"
              onClick={() => fetchNextPage()}
              disabled={isFetchingNextPage}
              className="text-sm text-primary hover:underline disabled:opacity-50"
            >
              {isFetchingNextPage
                ? t('common:dashboard.loading', 'Carregant...')
                : t('activity:timeline.load_more', 'Carregar més')}
            </button>
          )}
        </>
      )}
    </section>
  )
}
