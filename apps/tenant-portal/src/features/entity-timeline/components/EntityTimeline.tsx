import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useInfiniteQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Download } from 'lucide-react'
import { useToast } from '@/hooks/use-toast'
import { useDebounce } from '@/hooks/useDebounce'
import { useTenant } from '@/contexts/TenantContext'
import {
  getEntityTimeline,
  markEntityTimelineSeen,
  type EntityTimelineType,
} from '../api/timelineService'
import { groupConsecutiveAuditEvents, isAuditGroup } from '../utils/groupAuditEvents'
import { TimelineComposer } from './TimelineComposer'
import { TimelineEvent } from './TimelineEvent'
import { TimelineAuditGroup } from './TimelineAuditGroup'
import { TimelineComment } from './TimelineComment'
import { TimelineFilters } from './TimelineFilters'
import { EntitySubscriptionToggle } from './EntitySubscriptionToggle'
import { TimelineSummaryBanner } from './TimelineSummaryBanner'
import { RiskAlertsBanner } from './RiskAlertsBanner'
import { useEntityTimelineRealtime } from '../api/useEntityTimelineRealtime'
import { VISIT_SUMMARY_MIN_ITEMS } from '../utils/formatVisitSummary'
import { invalidateEntityTimelineCaches } from '../api/invalidateEntityTimelineCaches'
import { downloadEntityTimelineExport } from '../api/exportTimelineService'
import { useTenantFeatures } from '../api/useTenantFeatures'
import {
  DEFAULT_TIMELINE_FILTERS,
  resolveTimelineDateRange,
  hasActiveTimelineFilters,
  type TimelineFilterState,
} from '../utils/timelineFilters'

interface EntityTimelineProps {
  entityType: EntityTimelineType
  entityId: string
  siteId?: string | null
  onUnreadChange?: (count: number) => void
}

export function EntityTimeline({
  entityType,
  entityId,
  siteId,
  onUnreadChange,
}: EntityTimelineProps) {
  const { t } = useTranslation('activity')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { data: features } = useTenantFeatures()
  const queryClient = useQueryClient()
  const [searchParams] = useSearchParams()
  const highlightId = searchParams.get('comment')
  const [filters, setFilters] = useState<TimelineFilterState>(DEFAULT_TIMELINE_FILTERS)
  const timelineListRef = useRef<HTMLUListElement>(null)
  const markedSeenRef = useRef(false)
  const { includeAudit, includeBackground, tasksOnly, openTasksOnly } = filters
  const debouncedSearch = useDebounce(filters.search.trim(), 300)
  const { dateFrom, dateTo } = useMemo(() => resolveTimelineDateRange(filters), [filters])

  const queryKey = useMemo(
    () => [
      'entity-timeline',
      entityType,
      entityId,
      includeAudit,
      includeBackground,
      tasksOnly,
      openTasksOnly,
      dateFrom,
      dateTo,
      debouncedSearch,
    ],
    [entityType, entityId, includeAudit, includeBackground, tasksOnly, openTasksOnly, dateFrom, dateTo, debouncedSearch],
  )

  useEntityTimelineRealtime(entityType, entityId)

  const {
    data,
    isLoading,
    isError,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isFetching,
  } = useInfiniteQuery({
    queryKey,
    initialPageParam: { cursor: null as string | null, cursorId: null as string | null },
    queryFn: ({ pageParam }) =>
      getEntityTimeline({
        entityType,
        entityId,
        cursor: pageParam.cursor,
        cursorId: pageParam.cursorId,
        includeAudit,
        includeBackground,
        tasksOnly,
        openTasksOnly,
        dateFrom,
        dateTo,
        search: debouncedSearch || undefined,
      }),
    getNextPageParam: (lastPage) => {
      if (!lastPage?.page) return undefined
      return lastPage.page.has_more
        ? { cursor: lastPage.page.next_cursor, cursorId: lastPage.page.next_cursor_id }
        : undefined
    },
    staleTime: 0,
    refetchOnMount: 'always',
  })

  const items = useMemo(
    () => data?.pages.flatMap((p) => p.items) ?? [],
    [data],
  )

  const displayItems = useMemo(() => groupConsecutiveAuditEvents(items), [items])

  const unread = data?.pages[0]?.page.unread_since_last_visit ?? 0
  const showSummaryBanner =
    !hasActiveTimelineFilters(filters)
    && !debouncedSearch
    && unread >= VISIT_SUMMARY_MIN_ITEMS

  const markSeen = useCallback(() => {
    if (markedSeenRef.current) return
    markedSeenRef.current = true
    markEntityTimelineSeen(entityType, entityId)
      .then(() => {
        queryClient.invalidateQueries({ queryKey: ['entity-timeline-unread', entityType, entityId] })
        queryClient.invalidateQueries({ queryKey })
      })
      .catch(() => {})
  }, [entityType, entityId, queryClient, queryKey])

  const handleSummaryDismiss = useCallback(() => {
    markSeen()
  }, [markSeen])

  useEffect(() => {
    markedSeenRef.current = false
  }, [entityType, entityId])

  useEffect(() => {
    if (isLoading || showSummaryBanner) return
    markSeen()
  }, [isLoading, showSummaryBanner, markSeen])

  useEffect(() => {
    if (showSummaryBanner) return

    const onScroll = () => {
      if (window.scrollY > 48) {
        markSeen()
      }
    }

    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [showSummaryBanner, markSeen])

  useEffect(() => {
    onUnreadChange?.(unread)
  }, [unread, onUnreadChange])

  // Deep link (?comment=) des de notificació: cache pot estar obsoleta (staleTime global 5 min)
  useEffect(() => {
    if (!highlightId) return
    void invalidateEntityTimelineCaches(queryClient, entityType, entityId)
  }, [highlightId, entityType, entityId, queryClient])

  useEffect(() => {
    if (!highlightId || isLoading || isFetching || isFetchingNextPage) return
    if (items.some((item) => item.id === highlightId)) return
    if (hasNextPage) {
      void fetchNextPage()
    }
  }, [
    highlightId,
    items,
    hasNextPage,
    isLoading,
    isFetching,
    isFetchingNextPage,
    fetchNextPage,
  ])

  useEffect(() => {
    if (!highlightId) return
    const el = document.getElementById(`timeline-${highlightId}`)
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  }, [highlightId, items.length, isFetching])

  const invalidate = useCallback(() => {
    return invalidateEntityTimelineCaches(queryClient, entityType, entityId)
  }, [queryClient, entityType, entityId])

  const postMutation = useMutation({
    mutationFn: async (payload: {
      content: string
      isTask: boolean
      dueDate: string
      isAiContextNote: boolean
      parentId?: string
      attachments?: import('./TimelineAttachmentPicker').PendingAttachment[]
    }) => {
      const { insertEntityComment } = await import('../api/timelineService')
      return insertEntityComment({
        entityType,
        entityId,
        siteId,
        content: payload.content,
        isTask: payload.isTask,
        dueDate: payload.dueDate || null,
        isAiContextNote: payload.isAiContextNote,
        parentId: payload.parentId,
        attachments: payload.attachments,
      })
    },
    onSuccess: async () => {
      await invalidate()
    },
    onError: () => {
      toast({ variant: 'destructive', description: t('timeline.error_post', 'Error en publicar') })
    },
  })

  const exportMutation = useMutation({
    mutationFn: () => downloadEntityTimelineExport({
      entityType,
      entityId,
      dateFrom: dateFrom,
      dateTo: dateTo,
      includeAudit: includeAudit,
      includeBackground: includeBackground,
    }),
    onSuccess: (result) => {
      toast({
        description: result.integrityHash
          ? t('timeline.export_success_hash', 'Export descarregat. Hash: {{hash}}', {
            hash: result.integrityHash.slice(0, 12) + '…',
          })
          : t('timeline.export_success', 'Export CSV descarregat'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: t('timeline.export_error', 'No s\'ha pogut exportar la timeline'),
      })
    },
  })

  if (isLoading) {
    return (
      <div className="space-y-4">
        <TimelineFilters filters={filters} onChange={setFilters} />
        <p className="text-sm text-muted-foreground py-4">
          {t('timeline.loading', 'Carregant activitat...')}
        </p>
      </div>
    )
  }

  if (isError) {
    return (
      <div className="space-y-4">
        <TimelineFilters filters={filters} onChange={setFilters} />
        <p className="text-sm text-destructive py-4">
          {t('timeline.error_load', "Error en carregar l'activitat")}
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <TimelineComposer
        entityType={entityType}
        entityId={entityId}
        disabled={postMutation.isPending}
        onSubmit={(content, isTask, attachments, dueDate, isAiContextNote) =>
          postMutation.mutate({ content, isTask, attachments, dueDate, isAiContextNote })
        }
      />

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <TimelineFilters filters={filters} onChange={setFilters} />
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {features?.entity_timeline_export !== false && (
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={exportMutation.isPending}
              onClick={() => exportMutation.mutate()}
              className="hidden sm:inline-flex"
            >
              <Download className="h-4 w-4 mr-1.5" />
              {t('timeline.export_csv', 'Exportar CSV')}
            </Button>
          )}
          <EntitySubscriptionToggle entityType={entityType} entityId={entityId} />
        </div>
      </div>

      {features?.entity_timeline_risk_detector !== false && (
        <RiskAlertsBanner entityType={entityType} entityId={entityId} />
      )}

      <TimelineSummaryBanner
        entityType={entityType}
        entityId={entityId}
        unreadCount={unread}
        enabled={showSummaryBanner}
        onDismiss={handleSummaryDismiss}
      />

      {displayItems.length === 0 ? (
        <p className="text-sm text-muted-foreground py-6 text-center">
          {debouncedSearch
            ? t('timeline.empty_search', 'Cap comentari coincideix amb la cerca.')
            : hasActiveTimelineFilters(filters)
              ? t('timeline.empty_filtered', 'Cap activitat coincideix amb els filtres.')
              : t('timeline.empty', 'Encara no hi ha activitat.')}
        </p>
      ) : (
        <ul ref={timelineListRef} className="mt-6 space-y-6">
          {displayItems.map((item) => (
            <li
              key={isAuditGroup(item) ? item.id : `${item.kind}-${item.id}`}
              id={`timeline-${isAuditGroup(item) ? item.id : item.id}`}
              className={
                !isAuditGroup(item) && highlightId === item.id
                  ? 'rounded-xl border-2 border-primary/50 bg-primary/[0.04] p-1'
                  : undefined
              }
            >
              {isAuditGroup(item) ? (
                <TimelineAuditGroup events={item.events} />
              ) : item.kind === 'audit_event' ? (
                <TimelineEvent item={item} />
              ) : (
                <TimelineComment
                  item={item}
                  entityType={entityType}
                  entityId={entityId}
                  siteId={siteId}
                  highlighted={highlightId === item.id}
                  onChanged={invalidate}
                />
              )}
            </li>
          ))}
        </ul>
      )}

      {hasNextPage && (
        <div className="flex justify-center pt-2">
          <Button
            variant="outline"
            size="sm"
            disabled={isFetchingNextPage}
            onClick={() => fetchNextPage()}
          >
            {t('timeline.load_more', 'Carregar més')}
          </Button>
        </div>
      )}
    </div>
  )
}
