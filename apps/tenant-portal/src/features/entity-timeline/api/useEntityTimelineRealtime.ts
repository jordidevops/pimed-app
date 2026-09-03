import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { RealtimeChannel } from '@supabase/supabase-js'
import type { EntityTimelineType } from './timelineService'

interface EntityRow {
  entity_id?: string
  entity_type?: string
}

/**
 * Subscriu-se a canvis en temps real de comentaris i events d'audit per una entitat.
 * Nota: usa schema 'data' perquè les vistes api.* no emeten events Realtime.
 */
export function useEntityTimelineRealtime(
  entityType: EntityTimelineType,
  entityId: string | undefined,
) {
  const queryClient = useQueryClient()
  const flushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (!entityId) return

    let channel: RealtimeChannel | null = null

    const scheduleInvalidate = () => {
      if (flushTimerRef.current) return
      flushTimerRef.current = setTimeout(() => {
        queryClient.invalidateQueries({
          queryKey: ['entity-timeline', entityType, entityId],
        })
        queryClient.invalidateQueries({
          queryKey: ['entity-timeline-unread', entityType, entityId],
        })
        queryClient.invalidateQueries({ queryKey: ['my-open-tasks'] })
        flushTimerRef.current = null
      }, 500)
    }

    const matchesEntity = (row: EntityRow) =>
      row.entity_id === entityId && row.entity_type === entityType

    const handleChange = (payload: { new: EntityRow }) => {
      if (matchesEntity(payload.new)) {
        scheduleInvalidate()
      }
    }

    channel = supabase
      .channel(`timeline:${entityType}:${entityId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'data',
          table: 'entity_comments',
          filter: `entity_id=eq.${entityId}`,
        },
        handleChange,
      )
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'data',
          table: 'entity_comments',
          filter: `entity_id=eq.${entityId}`,
        },
        handleChange,
      )
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'data',
          table: 'audit_logs',
          filter: `entity_id=eq.${entityId}`,
        },
        handleChange,
      )
      .subscribe()

    return () => {
      if (flushTimerRef.current) {
        clearTimeout(flushTimerRef.current)
        flushTimerRef.current = null
      }
      if (channel) supabase.removeChannel(channel)
    }
  }, [entityType, entityId, queryClient])
}
