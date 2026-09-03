import type { QueryClient } from '@tanstack/react-query'
import type { EntityTimelineType } from './timelineService'

/** Invalida timeline, unread i tasques obertes del dashboard després de mutacions. */
export function invalidateEntityTimelineCaches(
  queryClient: QueryClient,
  entityType: EntityTimelineType,
  entityId: string,
) {
  return Promise.all([
    queryClient.invalidateQueries({ queryKey: ['entity-timeline', entityType, entityId] }),
    queryClient.invalidateQueries({ queryKey: ['entity-timeline-unread', entityType, entityId] }),
    queryClient.invalidateQueries({ queryKey: ['my-open-tasks'] }),
  ])
}
