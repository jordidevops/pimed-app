import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronDown, ChevronUp, Layers } from 'lucide-react'
import type { TimelineAuditItem } from '../api/timelineService'
import { formatAuditGroupSummary } from '../utils/formatAuditGroupSummary'
import { TimelineEvent } from './TimelineEvent'

function formatRelativeTime(iso: string): string {
  const d = new Date(iso)
  const diff = Date.now() - d.getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'ara'
  if (mins < 60) return `fa ${mins} min`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `fa ${hours} h`
  return d.toLocaleDateString('ca-ES', { day: 'numeric', month: 'short' })
}

interface TimelineAuditGroupProps {
  events: TimelineAuditItem[]
}

export function TimelineAuditGroup({ events }: TimelineAuditGroupProps) {
  const { t } = useTranslation('activity')
  const [expanded, setExpanded] = useState(false)
  const summary = formatAuditGroupSummary(t, events)
  const latestAt = events[0]?.created_at
  const actorName = events[0]?.actor?.full_name ?? t('timeline.system', 'Sistema')

  if (expanded) {
    return (
      <div className="space-y-3">
        <button
          type="button"
          className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
          onClick={() => setExpanded(false)}
        >
          <ChevronUp className="h-3.5 w-3.5" aria-hidden />
          {t('audit_group.collapse', {
            count: events.length,
            defaultValue: 'Amagar {{count}} events',
          })}
        </button>
        <div className="space-y-4 pl-1 border-l-2 border-muted ml-4">
          {events.map((event) => (
            <TimelineEvent key={event.id} item={event} />
          ))}
        </div>
      </div>
    )
  }

  return (
    <button
      type="button"
      className="w-full text-left rounded-lg border border-dashed border-border/80 bg-muted/20 px-3 py-2.5 hover:bg-muted/40 transition-colors"
      onClick={() => setExpanded(true)}
      aria-expanded={false}
    >
      <div className="flex gap-3 text-sm">
        <div className="h-8 w-8 rounded-full bg-muted flex items-center justify-center shrink-0">
          <Layers className="h-4 w-4 text-muted-foreground" aria-hidden />
        </div>
        <div className="flex-1 min-w-0">
          <p className="text-foreground">{summary}</p>
          <p className="text-xs text-muted-foreground mt-0.5">
            {t('audit_group.expand_hint', {
              count: events.length,
              actor: actorName,
              defaultValue: '{{count}} events similars de {{actor}} · clic per veure',
            })}
          </p>
          {latestAt && (
            <p className="text-xs text-muted-foreground mt-0.5 flex items-center gap-1">
              {formatRelativeTime(latestAt)}
              <ChevronDown className="h-3 w-3 opacity-60" aria-hidden />
            </p>
          )}
        </div>
      </div>
    </button>
  )
}
