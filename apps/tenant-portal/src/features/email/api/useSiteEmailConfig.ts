import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { SiteEmailConfig } from '../types'

export function useSiteEmailConfig(siteId: string | null) {
  return useQuery<SiteEmailConfig | null>({
    queryKey: emailKeys.siteConfig(siteId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('sites')
        .select(
          'id, tenant_id, email_from_name, email_reply_to, email_logo_url, email_tenant_name_fallback, default_email_layout_id',
        )
        .eq('id', siteId!)
        .single()
      if (error) throw error
      return data as SiteEmailConfig
    },
    enabled: !!siteId,
  })
}
