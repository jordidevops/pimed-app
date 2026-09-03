import { useTranslation } from 'react-i18next'
import type { TimelineAuditItem } from '../api/timelineService'
import { resolveTimelineAuditAvatar } from '../utils/timelineAuditAvatar'

interface TimelineAuditAvatarProps {
  item: TimelineAuditItem
  className?: string
}

export function TimelineAuditAvatar({ item, className }: TimelineAuditAvatarProps) {
  const { t } = useTranslation('activity')
  const avatar = resolveTimelineAuditAvatar(item)
  const baseClass = `h-8 w-8 rounded-full flex items-center justify-center shrink-0 ${className ?? ''}`

  if (avatar.type === 'initial') {
    return (
      <div
        className={`${baseClass} ${avatar.className} text-xs`}
        title={avatar.label}
        aria-label={avatar.label}
      >
        {avatar.initial}
      </div>
    )
  }

  const label = t(avatar.labelKey, avatar.labelDefault)
  const Icon = avatar.Icon

  return (
    <div
      className={`${baseClass} ${avatar.className}`}
      title={label}
      aria-label={label}
    >
      <Icon className="h-4 w-4" aria-hidden />
    </div>
  )
}
