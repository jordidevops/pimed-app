import { useMutation } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import type { Json } from '../../../types/database.types'

interface SendTestEmailParams {
  tenantId: string
  site_id: string | null
  to: string
  senderProfileId?: string
  locale?: string
}

export function useSendTestEmail() {
  return useMutation({
    mutationFn: async ({ tenantId, site_id, to, senderProfileId, locale }: SendTestEmailParams) => {
      const idempotencyKey = `test-email-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`

      const payloadFields: Record<string, unknown> = {
        tenant_id: tenantId,
        site_id,
        idempotency_key: idempotencyKey,
        to: [to],
        event_type: 'test-email',
        template_variables: { app_name: 'La teva Startup' },
        locale: locale ?? 'ca',
      }

      if (senderProfileId) {
        payloadFields.sender_profile_id = senderProfileId
      }

      if (locale) {
        payloadFields.locale = locale
      }

      const { data, error } = await supabase.rpc('enqueue_email', {
        payload: payloadFields as Json,
      })

      if (error) throw error
      return data as string
    },
  })
}
