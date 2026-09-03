import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { RealtimeChannel } from '@supabase/supabase-js'

/**
 * Invalida el recompte i la safata quan arriba una notificació in-app nova
 * o quan es marca com a llegida (worker o usuari).
 */
export function useNotificationsRealtime(userId: string | undefined) {
  const queryClient = useQueryClient()
  const flushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (!userId) return

    let channel: RealtimeChannel | null = null

    const scheduleInvalidate = () => {
      if (flushTimerRef.current) return
      flushTimerRef.current = setTimeout(() => {
        queryClient.invalidateQueries({ queryKey: ['notifications-unread-count'] })
        queryClient.invalidateQueries({ queryKey: ['notifications-inbox'] })
        flushTimerRef.current = null
      }, 300)
    }

    const matchesUser = (row: { user_id?: string }) => row.user_id === userId

    channel = supabase
      .channel(`notifications:${userId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'data',
          table: 'notifications',
          filter: `user_id=eq.${userId}`,
        },
        (payload) => {
          if (matchesUser(payload.new as { user_id?: string })) {
            scheduleInvalidate()
          }
        },
      )
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'data',
          table: 'notifications',
          filter: `user_id=eq.${userId}`,
        },
        (payload) => {
          if (matchesUser(payload.new as { user_id?: string })) {
            scheduleInvalidate()
          }
        },
      )
      .subscribe()

    return () => {
      if (flushTimerRef.current) {
        clearTimeout(flushTimerRef.current)
        flushTimerRef.current = null
      }
      if (channel) supabase.removeChannel(channel)
    }
  }, [userId, queryClient])
}
