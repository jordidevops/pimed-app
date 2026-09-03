import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { RealtimeChannel } from '@supabase/supabase-js'
import type { SigningStatus } from './signingService'

export type SigningAlertStatus = 'completed' | 'declined' | 'error'

export interface SigningAlertEvent {
  id:     string
  status: SigningAlertStatus
}

const ALERT_STATUSES: SigningStatus[] = ['completed', 'declined', 'error']

/**
 * Subscriu-se a canvis en temps real de data.signing_submissions per al tenant actiu.
 * Nota: usa schema:'data' perquè les vistes api.* no emeten events Realtime.
 * Invalida totes les queries de submissions i crida onAlert per als estats crítics.
 */
export function useSigningSubmissionsRealtime(
  tenantId: string | undefined,
  onAlert: (event: SigningAlertEvent) => void,
) {
  const queryClient = useQueryClient()
  const onAlertRef  = useRef(onAlert)
  const flushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pendingIdsRef = useRef<Set<string>>(new Set())
  const lastAlertAtRef = useRef<number>(0)
  useEffect(() => { onAlertRef.current = onAlert })

  useEffect(() => {
    if (!tenantId) return

    let channel: RealtimeChannel | null = null

    const handleChange = (payload: { new: { id: string; status: string } }) => {
      const row = payload.new

      pendingIdsRef.current.add(row.id)
      if (!flushTimerRef.current) {
        flushTimerRef.current = setTimeout(() => {
          queryClient.invalidateQueries({ queryKey: ['signing', 'submissions', tenantId] })

          for (const submissionId of pendingIdsRef.current) {
            queryClient.invalidateQueries({ queryKey: ['signing', 'submission', submissionId] })
            queryClient.invalidateQueries({ queryKey: ['signing', 'events', submissionId] })
          }

          queryClient.invalidateQueries({ queryKey: ['signing', 'version_submission'] })

          pendingIdsRef.current.clear()
          flushTimerRef.current = null
        }, 1000)
      }

      if (ALERT_STATUSES.includes(row.status as SigningStatus)) {
        const now = Date.now()
        if (now - lastAlertAtRef.current >= 3000) {
          onAlertRef.current({ id: row.id, status: row.status as SigningAlertStatus })
          lastAlertAtRef.current = now
        }
      }
    }

    channel = supabase
      .channel(`signing-submissions:${tenantId}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'data', table: 'signing_submissions',
        filter: `tenant_id=eq.${tenantId}`,
      }, handleChange)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'data', table: 'signing_submissions',
        filter: `tenant_id=eq.${tenantId}`,
      }, handleChange)
      .subscribe()

    return () => {
      if (flushTimerRef.current) {
        clearTimeout(flushTimerRef.current)
        flushTimerRef.current = null
      }
      pendingIdsRef.current.clear()
      if (channel) supabase.removeChannel(channel)
    }
  }, [tenantId, queryClient])
}
