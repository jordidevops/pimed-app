import type { TFunction } from 'i18next'
import type { EntityTimelineVisitSummary } from '../api/timelineService'
import { formatAuditMessage } from '../registry/timelineAuditRegistry'

export interface VisitSummaryHighlight {
  kind: string
  action?: string | null
  message_vars?: Record<string, unknown>
  content?: string | null
  is_task?: boolean
  resolved_at?: string | null
  actor_name?: string | null
  created_at?: string
}

/** Mostra el banner només si hi ha més de 5 items nous (pla §10.2). */
export const VISIT_SUMMARY_MIN_ITEMS = 6

export function visitSummaryDismissKey(entityType: string, entityId: string): string {
  return `timeline-summary-dismissed:${entityType}:${entityId}`
}

function formatSinceDate(lastSeenAt: string | null, locale = 'ca-ES'): string {
  if (!lastSeenAt) {
    return ''
  }
  const d = new Date(lastSeenAt)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString(locale, { day: 'numeric', month: 'long' })
}

function decodeMentionPreview(content: string): string {
  return content
    .replace(/\[\[@([0-9a-fA-F-]{36})\|([^\]]+)\]\]/g, '@$2')
    .replace(/\s+/g, ' ')
    .trim()
}

function formatHighlightLine(t: TFunction, item: VisitSummaryHighlight): string {
  if (item.kind === 'audit_event' && item.action) {
    return formatAuditMessage(
      t,
      item.action,
      item.message_vars ?? {},
      item.actor_name,
    )
  }
  const preview = decodeMentionPreview(item.content ?? '')
  if (!preview) return ''
  if (item.is_task) {
    return item.resolved_at
      ? t('activity:visit_summary.highlight_task_done', {
          preview,
          defaultValue: 'Tasca resolta: «{{preview}}»',
        })
      : t('activity:visit_summary.highlight_task_new', {
          preview,
          defaultValue: 'Tasca nova: «{{preview}}»',
        })
  }
  return t('activity:visit_summary.highlight_comment', {
    preview,
    defaultValue: '«{{preview}}»',
  })
}

export function formatVisitSummaryNarrative(
  t: TFunction,
  summary: EntityTimelineVisitSummary,
): { headline: string; bullets: string[] } {
  const since = formatSinceDate(summary.last_seen_at)
  const parts: string[] = []

  if (summary.comments_new > 0) {
    parts.push(
      t('activity:visit_summary.comments', {
        count: summary.comments_new,
        defaultValue: '{{count}} comentaris nous',
      }),
    )
  }
  if (summary.audit_events_new > 0) {
    parts.push(
      t('activity:visit_summary.audit', {
        count: summary.audit_events_new,
        defaultValue: '{{count}} events del sistema',
      }),
    )
  }
  if (summary.tasks_new > 0) {
    parts.push(
      t('activity:visit_summary.tasks_open', {
        count: summary.tasks_new,
        defaultValue: '{{count}} tasques noves (pendents)',
      }),
    )
  }
  if (summary.tasks_resolved_new > 0) {
    parts.push(
      t('activity:visit_summary.tasks_done', {
        count: summary.tasks_resolved_new,
        defaultValue: '{{count}} tasques resoltes',
      }),
    )
  }

  const headline = since
    ? t('activity:visit_summary.headline_since', {
        since,
        parts: parts.join(', '),
        defaultValue: 'Des del {{since}}: {{parts}}.',
      })
    : t('activity:visit_summary.headline_first', {
        parts: parts.join(', '),
        defaultValue: 'Des de la teva primera visita: {{parts}}.',
      })

  const bullets = summary.highlights
    .map((h) => formatHighlightLine(t, h))
    .filter((line) => line.length > 0)
    .slice(0, 4)

  return { headline, bullets }
}
