import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailConfigUpsert } from '../types'
import type { Database, Json } from '../../../types/database.types'

type EmailConfigInsert = Database['api']['Views']['email_configs']['Insert']

export function useUpsertEmailConfig(tenantId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (values: EmailConfigUpsert) => {
      const payload: EmailConfigInsert = {
        ...values,
        layout_variables: (values.layout_variables ?? null) as Json | null,
        metadata: (values.metadata ?? null) as Json | null,
        tenant_id: tenantId,
      }

      const { data, error } = await supabase
        .from('email_configs')
        .upsert(payload, { onConflict: 'tenant_id' })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: emailKeys.config(tenantId) })
    },
  })
}
