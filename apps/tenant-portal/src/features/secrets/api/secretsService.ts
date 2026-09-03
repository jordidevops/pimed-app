import { supabase } from '@/lib/supabase'

export type TenantSecretMeta = {
  id: string
  secret_type: string
  provider: string
  label: string | null
  key_version: number
  rotation_status: string
  last_rotated_at: string | null
  rotation_due_at: string | null
  created_at: string
  updated_at: string
}

export type SecretRotationLogEntry = {
  id: string
  secret_type: string
  provider: string | null
  old_key_version: number
  new_key_version: number
  rotation_type: string
  initiated_by: string | null
  completed_at: string | null
  status: string
  created_at: string
}

export async function listTenantSecrets(tenantId: string): Promise<TenantSecretMeta[]> {
  const { data, error } = await supabase.rpc('list_tenant_secrets', {
    p_tenant_id: tenantId,
  })
  if (error) throw error
  return (data ?? []) as TenantSecretMeta[]
}

export async function listSecretRotationLog(
  tenantId: string,
  limit = 20,
): Promise<SecretRotationLogEntry[]> {
  const { data, error } = await supabase.rpc('list_secret_rotation_log', {
    p_tenant_id: tenantId,
    p_limit: limit,
  })
  if (error) throw error
  return (data ?? []) as SecretRotationLogEntry[]
}

/** Enllaços a pàgines de configuració per actualitzar cada tipus de secret. */
export function secretSettingsLink(secretType: string): string | null {
  switch (secretType) {
    case 'ai_api_key':
      return '/settings/ai'
    case 'twilio_auth_token':
    case 'onesignal_key':
      return '/settings/notifications'
    case 'storage_secret_key':
      return '/settings/storage'
    case 'docuseal_key':
      return '/settings/signing'
    case 'webhook_secret':
      return '/settings/webhooks'
    case 'geocoding_api_key':
    case 'routes_api_key':
    case 'maps_js_api_key':
      return '/settings/maps'
    default:
      return null
  }
}
