import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { SiteEmailConfigUpdate } from '../types'

export function useUpdateSiteEmailConfig(tenantId: string) {
  const qc = useQueryClient()

  return useMutation({
    mutationFn: async ({
      siteId,
      updates,
    }: {
      siteId: string
      updates: SiteEmailConfigUpdate
    }) => {
      const { data, error } = await supabase
        .from('sites')
        .update(updates)
        .eq('id', siteId)
        .select(
          'id, tenant_id, email_from_name, email_reply_to, email_logo_url, email_tenant_name_fallback, default_email_layout_id',
        )
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_data, { siteId }) => {
      qc.invalidateQueries({ queryKey: emailKeys.siteConfig(siteId) })
      // Invalidate the sites list so TenantContext picks up changes
      qc.invalidateQueries({ queryKey: ['sites', tenantId] })
    },
  })
}
