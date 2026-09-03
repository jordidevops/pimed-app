import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

/** The current BYOS provider config readable by the frontend (no secret_key_id). */
export interface StorageProviderConfig {
  id: string
  tenant_id: string
  provider_type: 'supabase' | 's3' | 'r2' | 'gcs'
  endpoint_url: string | null
  bucket_name: string | null
  region: string | null
  is_verified: boolean
  is_active: boolean
  created_at: string
  updated_at: string
}

/**
 * Fetches the current storage provider record for a tenant.
 * The api.storage_provider view is restricted by RLS — owner/manager only.
 * Returns null when no BYOS provider has been configured yet
 * (tenant is using Supabase Storage by default).
 *
 * Note: `access_key` and `secret_key_id` are intentionally NOT returned
 * by the view — the secret key lives in Vault and never travels to the client.
 */
export function useStorageProvider(tenantId: string | undefined) {
  return useQuery<StorageProviderConfig | null>({
    queryKey: ['storage-provider', tenantId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('storage_provider')
        .select('*')
        .eq('tenant_id', tenantId!)
        .maybeSingle()

      if (error) throw error
      return data as StorageProviderConfig | null
    },
    enabled: !!tenantId,
  })
}
