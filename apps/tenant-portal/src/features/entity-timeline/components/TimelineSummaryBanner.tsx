import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { Sparkles, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  getEntityTimelineVisitSummary,
  type EntityTimelineType,
} from '../api/timelineService'
import {
  formatVisitSummaryNarrative,
  visitSummaryDismissKey,
  VISIT_SUMMARY_MIN_ITEMS,
} from '../utils/formatVisitSummary'

interface TimelineSummaryBannerProps {
  entityType: EntityTimelineType
  entityId: string
  unreadCount: number
  enabled: boolean
  onDismiss: () => void
}

export function TimelineSummaryBanner({
  entityType,
  entityId,
  unreadCount,
  enabled,
  onDismiss,
}: TimelineSummaryBannerProps) {
  const { t } = useTranslation('activity')
  const [dismissed, setDismissed] = useState(() => {
    try {
      return sessionStorage.getItem(visitSummaryDismissKey(entityType, entityId)) === '1'
    } catch {
      return false
    }
  })

  const shouldFetch =
    enabled && !dismissed && unreadCount >= VISIT_SUMMARY_MIN_ITEMS

  const { data: summary, isLoading, isError } = useQuery({
    queryKey: ['entity-timeline-visit-summary', entityType, entityId],
    queryFn: () => getEntityTimelineVisitSummary(entityType, entityId),
    enabled: shouldFetch,
    staleTime: Infinity,
  })

  useEffect(() => {
    if (dismissed) {
      onDismiss()
    }
  }, [dismissed, onDismiss])

  useEffect(() => {
    if (!shouldFetch || isLoading) return
    if (isError || !summary || summary.total_new < VISIT_SUMMARY_MIN_ITEMS) {
      onDismiss()
    }
  }, [shouldFetch, isLoading, isError, summary, onDismiss])

  if (!shouldFetch || dismissed || isLoading || isError || !summary) {
    return null
  }

  if (summary.total_new < VISIT_SUMMARY_MIN_ITEMS) {
    return null
  }

  const { headline, bullets } = formatVisitSummaryNarrative(t, summary)

  function handleDismiss() {
    try {
      sessionStorage.setItem(visitSummaryDismissKey(entityType, entityId), '1')
    } catch {
      /* ignore */
    }
    setDismissed(true)
    onDismiss()
  }

  return (
    <div
      role="status"
      className="rounded-xl border border-violet-200 bg-violet-50/80 dark:border-violet-800/60 dark:bg-violet-950/30 px-4 py-3 space-y-2"
    >
      <div className="flex items-start gap-3">
        <Sparkles className="h-5 w-5 text-violet-600 dark:text-violet-400 shrink-0 mt-0.5" aria-hidden />
        <div className="flex-1 min-w-0 space-y-1.5">
          <p className="text-sm font-medium text-foreground">
            {t('activity:visit_summary.title', 'Novetats des de la teva última visita')}
          </p>
          <p className="text-sm text-muted-foreground">{headline}</p>
          {bullets.length > 0 && (
            <ul className="text-sm text-muted-foreground list-disc pl-4 space-y-0.5">
              {bullets.map((line, i) => (
                <li key={i}>{line}</li>
              ))}
            </ul>
          )}
        </div>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 shrink-0 text-muted-foreground"
          onClick={handleDismiss}
          aria-label={t('activity:visit_summary.dismiss', 'Tancar resum')}
        >
          <X className="h-4 w-4" />
        </Button>
      </div>
    </div>
  )
}
