import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { DnsRecord, EmailDomain } from '../types'

export function useEmailDomains(tenantId: string | undefined) {
  return useQuery<EmailDomain[]>({
    queryKey: emailKeys.domains(tenantId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('email_domains')
        .select('*')
        .eq('tenant_id', tenantId!)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? [])
        .filter((row): row is NonNullable<typeof row> => !!row)
        .map((row) => ({
          id: row.id ?? '',
          tenant_id: row.tenant_id ?? tenantId ?? '',
          domain: row.domain ?? '',
          verification_status: row.verification_status ?? 'pending',
          dns_records: (row.dns_records as DnsRecord[] | null) ?? null,
          provider_domain_id: row.provider_domain_id,
          verified_at: row.verified_at,
          is_primary: row.is_primary ?? false,
          default_from_email: row.default_from_email,
          default_from_name: row.default_from_name,
          default_reply_to: row.default_reply_to,
          created_at: row.created_at ?? '',
          updated_at: row.updated_at ?? '',
        }))
        .filter((row) => row.id.length > 0 && row.domain.length > 0)
    },
    enabled: !!tenantId,
  })
}
