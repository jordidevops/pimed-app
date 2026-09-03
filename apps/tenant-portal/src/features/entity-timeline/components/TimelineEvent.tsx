import { useTranslation } from 'react-i18next'
import { formatAuditMessage } from '../registry/timelineAuditRegistry'
import type { TimelineAuditItem } from '../api/timelineService'
import { TimelineAuditAvatar } from './TimelineAuditAvatar'

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

interface TimelineEventProps {
  item: TimelineAuditItem
}

export function TimelineEvent({ item }: TimelineEventProps) {
  const { t } = useTranslation('activity')
  const messageActorName = item.actor?.full_name ?? undefined
  const text = formatAuditMessage(t, item.action, item.message_vars ?? {}, messageActorName)

  return (
    <div className={`flex gap-3 text-sm ${item.is_background ? 'opacity-80' : ''}`}>
      <TimelineAuditAvatar item={item} />
      <div className="flex-1 min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-foreground">{text}</p>
          {item.is_background && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-muted text-muted-foreground">
              {t('timeline.background_badge', 'Automàtic')}
            </span>
          )}
        </div>
        <p className="text-xs text-muted-foreground mt-0.5">{formatRelativeTime(item.created_at)}</p>
      </div>
    </div>
  )
}
