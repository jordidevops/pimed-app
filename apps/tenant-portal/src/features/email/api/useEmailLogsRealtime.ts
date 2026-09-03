import { useEffect, useRef } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import type { RealtimeChannel } from '@supabase/supabase-js'

export type EmailAlertStatus = 'bounced' | 'failed'

export interface EmailAlertEvent {
  id: string
  to_emails: string[]
  subject: string | null
  status: EmailAlertStatus
}

/**
 * Subscriu-se a canvis en temps real de data.email_logs per al tenant actiu.
 * Quan un correu passa a 'bounced' o 'failed', invoca `onAlert` perquè
 * el component contenidor pugui llançar un toast (sense acoblar el hook a
 * cap sistema de UI concret).
 *
 * Nota: usa schema:'data' perquè les views api.* no emeten events Realtime.
 * Escolta tant INSERT (nous correus encuats) com UPDATE (canvis d'estat).
 */
export function useEmailLogsRealtime(
  tenantId: string | undefined,
  onAlert: (event: EmailAlertEvent) => void,
) {
  const queryClient = useQueryClient()
  // Ref per evitar stale closure al callback d'alert
  const onAlertRef = useRef(onAlert)
  useEffect(() => {
    onAlertRef.current = onAlert
  })

  useEffect(() => {
    if (!tenantId) return

    let channel: RealtimeChannel | null = null

    const handleChange = (payload: {
      new: {
        id: string
        to_emails: string[]
        subject: string | null
        status: string
      }
    }) => {
      const row = payload.new

      // Invalida la cache de logs per reflectir el canvi a la taula
      queryClient.invalidateQueries({
        queryKey: ['email', 'logs', tenantId],
      })

      // Notifica l'UI si l'estat és crític
      if (row.status === 'bounced' || row.status === 'failed') {
        onAlertRef.current({
          id: row.id,
          to_emails: row.to_emails ?? [],
          subject: row.subject,
          status: row.status as EmailAlertStatus,
        })
      }
    }

    channel = supabase
      .channel(`email-logs:${tenantId}`)
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'data',
          table: 'email_logs',
          filter: `tenant_id=eq.${tenantId}`,
        },
        handleChange,
      )
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'data',
          table: 'email_logs',
          filter: `tenant_id=eq.${tenantId}`,
        },
        handleChange,
      )
      .subscribe()

    return () => {
      if (channel) supabase.removeChannel(channel)
    }
  }, [tenantId, queryClient])
}
