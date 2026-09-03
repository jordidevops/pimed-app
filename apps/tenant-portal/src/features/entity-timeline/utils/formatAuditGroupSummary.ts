import type { TFunction } from 'i18next'
import type { TimelineAuditItem } from '../api/timelineService'
import { stripEntityActionPrefix } from '../registry/timelineAuditRegistry'

export function formatAuditGroupSummary(
  t: TFunction,
  events: TimelineAuditItem[],
): string {
  const action = events[0]?.action ?? ''
  const actorName = events[0]?.actor?.full_name
  const count = events.length
  const prefix = actorName ? `${actorName} ` : ''
  const shortAction = stripEntityActionPrefix(action)

  switch (action) {
    case 'EMPLOYEE_UPDATED':
      return (
        prefix +
        t('activity:audit_group.EMPLOYEE_UPDATED', {
          count,
          defaultValue: `ha fet ${count} actualitzacions`,
        })
      )
    case 'CONTACT_UPDATED':
      return (
        prefix +
        t('activity:audit_group.CONTACT_UPDATED', {
          count,
          defaultValue: `ha actualitzat el contacte ${count} vegades`,
        })
      )
    default:
      return (
        prefix +
        t('activity:audit_group.generic', {
          count,
          action: shortAction,
          defaultValue: `${count}× ${shortAction}`,
        })
      )
  }
}
