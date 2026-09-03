import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

export interface EmailUsage {
  sent_hour: number
  sent_day: number
}

export function useEmailUsage(tenantId: string | undefined) {
  return useQuery<EmailUsage>({
    queryKey: ['email', 'usage', tenantId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_my_email_usage', {
        p_tenant_id: tenantId,
      })
      if (error) throw error

      if (!data || typeof data !== 'object' || Array.isArray(data)) {
        return { sent_hour: 0, sent_day: 0 }
      }

      const row = data as Record<string, unknown>
      return {
        sent_hour: typeof row.sent_hour === 'number' ? row.sent_hour : 0,
        sent_day: typeof row.sent_day === 'number' ? row.sent_day : 0,
      }
    },
    enabled: !!tenantId,
    staleTime: 30_000,
  })
}
