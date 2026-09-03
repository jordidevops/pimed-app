import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { TenantSigningStatus } from './signingService'

export function useSigningConfig(tenantId: string | undefined) {
  return useQuery<TenantSigningStatus | null>({
    queryKey: signingKeys.config(tenantId ?? ''),
    queryFn:  async () => {
      if (!tenantId) return null
      const { data, error } = await supabase
        .rpc('get_signing_status', { p_tenant_id: tenantId })

      if (error) throw error
      return data as TenantSigningStatus | null
    },
    enabled: !!tenantId,
  })
}
