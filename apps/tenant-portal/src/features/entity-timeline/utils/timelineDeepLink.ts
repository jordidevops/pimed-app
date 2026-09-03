import type { EntityTimelineType } from '../api/timelineService'

const ENTITY_ROUTE_PATTERN = /^\/(employees|contacts|projects|documents)\/([0-9a-f-]{36})/i

const ROUTE_TO_TYPE: Record<string, EntityTimelineType> = {
  employees: 'employee',
  contacts: 'contact',
  projects: 'project',
  documents: 'document',
}

export interface ParsedTimelineDeepLink {
  entityType: EntityTimelineType
  entityId: string
  commentId: string | null
}

/** Extreu entitat i comentari d'un deep link de timeline (notificacions, tasques obertes). */
export function parseTimelineDeepLink(deepLink: string): ParsedTimelineDeepLink | null {
  try {
    const url = deepLink.startsWith('http')
      ? new URL(deepLink)
      : new URL(deepLink, 'http://local')
    const match = url.pathname.match(ENTITY_ROUTE_PATTERN)
    if (!match) return null
    const entityType = ROUTE_TO_TYPE[match[1].toLowerCase()]
    if (!entityType) return null
    return {
      entityType,
      entityId: match[2],
      commentId: url.searchParams.get('comment'),
    }
  } catch {
    return null
  }
}
