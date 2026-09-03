import type { TimelineAuditItem, TimelineItem } from '../api/timelineService'

/** Accions que es poden col·lapsar si són consecutives i del mateix minut/actor. */
const GROUPABLE_ACTIONS = new Set(['EMPLOYEE_UPDATED', 'CONTACT_UPDATED'])

export interface TimelineAuditGroupItem {
  kind: 'audit_group'
  id: string
  events: TimelineAuditItem[]
}

export type TimelineDisplayItem = TimelineItem | TimelineAuditGroupItem

export function isAuditGroup(item: TimelineDisplayItem): item is TimelineAuditGroupItem {
  return item.kind === 'audit_group'
}

function minuteBucket(iso: string): string {
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function isGroupableAudit(item: TimelineAuditItem): boolean {
  return GROUPABLE_ACTIONS.has(item.action)
}

function canGroupWith(a: TimelineAuditItem, b: TimelineAuditItem): boolean {
  if (!isGroupableAudit(a) || a.action !== b.action) return false
  if (minuteBucket(a.created_at) !== minuteBucket(b.created_at)) return false
  const actorA = a.actor?.id ?? null
  const actorB = b.actor?.id ?? null
  return actorA === actorB
}

/**
 * Col·lapsa events d'audit similars consecutius (mateixa acció, actor i minut).
 * Els comentaris tallen una agrupació.
 */
export function groupConsecutiveAuditEvents(items: TimelineItem[]): TimelineDisplayItem[] {
  const result: TimelineDisplayItem[] = []
  let i = 0

  while (i < items.length) {
    const item = items[i]
    if (item.kind !== 'audit_event' || !isGroupableAudit(item)) {
      result.push(item)
      i += 1
      continue
    }

    const group: TimelineAuditItem[] = [item]
    let j = i + 1
    while (j < items.length) {
      const next = items[j]
      if (next.kind !== 'audit_event' || !canGroupWith(group[group.length - 1], next)) {
        break
      }
      group.push(next)
      j += 1
    }

    if (group.length >= 2) {
      result.push({
        kind: 'audit_group',
        id: `audit-group-${group[0].id}`,
        events: group,
      })
    } else {
      result.push(item)
    }
    i = j
  }

  return result
}
