'use server'

import { revalidatePath } from 'next/cache'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'

type BackofficeRole = 'admin' | 'support'
const BACKOFFICE_ROLES: BackofficeRole[] = ['admin', 'support']

async function assertAdmin(allowedRoles: BackofficeRole[] = BACKOFFICE_ROLES) {
  const supabase = await createSupabaseServerClient()
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as BackofficeRole | undefined
  if (!role || !allowedRoles.includes(role)) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }
  return { user, role }
}

export type PlatformSecretRow = {
  id: string
  secret_key: string
  description: string | null
  category: string
  key_version: number
  rotation_status: string
  last_rotated_at: string | null
  rotation_due_at: string | null
  last_rotation_alert_at: string | null
  rotated_by: string | null
  notes: string | null
}

export type SecretAccessLogRow = {
  id: string
  tenant_id: string | null
  secret_type: string
  provider: string | null
  accessed_by_fn: string
  access_reason: string | null
  created_at: string
}

export type TenantSecretMeta = {
  id: string
  secret_type: string
  provider: string
  label: string | null
  key_version: number
  rotation_status: string
  last_rotated_at: string | null
  rotation_due_at: string | null
}

export async function getPlatformSecrets(): Promise<PlatformSecretRow[]> {
  await assertAdmin()
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('list_platform_secrets')
  if (error) throw new Error(error.message)
  return (data ?? []) as PlatformSecretRow[]
}

export async function getSecretAccessLog(params: {
  tenantId?: string
  secretType?: string
  accessedByFn?: string
  limit?: number
}): Promise<SecretAccessLogRow[]> {
  await assertAdmin()
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('list_secret_access_log', {
    p_tenant_id: params.tenantId ?? null,
    p_secret_type: params.secretType ?? null,
    p_accessed_by_fn: params.accessedByFn ?? null,
    p_limit: params.limit ?? 100,
  })
  if (error) throw new Error(error.message)
  return (data ?? []) as SecretAccessLogRow[]
}

export async function logPlatformSecretRotation(formData: FormData) {
  await assertAdmin(['admin'])
  const secretKey = String(formData.get('secret_key') ?? '')
  const rotatedBy = String(formData.get('rotated_by') ?? '')
  const notes = String(formData.get('notes') ?? '') || null
  if (!secretKey) throw new Error('secret_key required')

  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('log_platform_secret_rotation', {
    p_secret_key: secretKey,
    p_rotated_by: rotatedBy || null,
    p_notes: notes,
    p_rotation_due_at: null,
  })
  if (error) throw new Error(error.message)
  revalidatePath('/dashboard/security/secrets')
}

export async function getTenantSecretsMeta(tenantId: string): Promise<TenantSecretMeta[]> {
  await assertAdmin()
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('list_tenant_secrets', { p_tenant_id: tenantId })
  if (error) throw new Error(error.message)
  return (data ?? []) as TenantSecretMeta[]
}

export async function adminRevokeTenantSecret(
  tenantId: string,
  secretType: string,
  provider: string,
) {
  await assertAdmin(['admin'])
  if (secretType === 'tenant_field_dek') {
    throw new Error(
      'tenant_field_dek no es pot revocar (rebrutaria IBAN/NSS). Usa rotate_tenant_field_dek.',
    )
  }
  const admin = createSupabaseAdminClient()
  const { error } = await admin.rpc('revoke_tenant_secret', {
    p_tenant_id: tenantId,
    p_secret_type: secretType,
    p_provider: provider,
  })
  if (error) throw new Error(error.message)
  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

/** Platform-only: re-encrypt all tenant PII fields with a new DEK. */
export async function adminRotateTenantFieldDek(tenantId: string) {
  await assertAdmin(['admin'])
  const admin = createSupabaseAdminClient()
  const { data, error } = await admin.rpc('rotate_tenant_field_dek', {
    p_tenant_id: tenantId,
  })
  if (error) throw new Error(error.message)
  revalidatePath(`/dashboard/tenants/${tenantId}`)
  return data as { ok: boolean; fields_reencrypted: number; new_key_version: number }
}
