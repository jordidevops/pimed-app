import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailConfig, EmailConfigMetadata } from '../types'

export function useEmailConfig(tenantId: string | undefined) {
  return useQuery<EmailConfig | null>({
    queryKey: emailKeys.config(tenantId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('email_configs')
        .select('*')
        .eq('tenant_id', tenantId!)
        .maybeSingle()
      if (error) throw error
      if (!data) return null

      return {
        tenant_id: data.tenant_id ?? tenantId ?? '',
        default_provider: data.default_provider ?? 'resend',
        default_from_name: data.default_from_name,
        default_reply_to: data.default_reply_to,
        default_layout_id: data.default_layout_id,
        layout_variables: (data.layout_variables as Record<string, string> | null) ?? null,
        rate_limit_per_hour: data.rate_limit_per_hour ?? 0,
        rate_limit_per_day: data.rate_limit_per_day ?? 0,
        max_retries: data.max_retries ?? 0,
        retention_days: data.retention_days ?? 0,
        custom_domains_enabled: data.custom_domains_enabled ?? false,
        max_custom_domains: data.max_custom_domains ?? 0,
        metadata: (data.metadata as EmailConfigMetadata | null) ?? null,
        logo_url: data.logo_url,
        tenant_name_fallback: data.tenant_name_fallback,
        created_at: data.created_at ?? '',
        updated_at: data.updated_at ?? '',
      }
    },
    enabled: !!tenantId,
  })
}
