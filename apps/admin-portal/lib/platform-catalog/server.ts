/**
 * Server-only guard for the platform catalog actions.
 *
 * Every write in these catalogs targets rows with `tenant_id IS NULL`, which the
 * database only accepts from the service_role path — so all mutations go through
 * `createSupabaseAdminClient()` after the caller has been checked here.
 */

import { createSupabaseServerClient } from '@/lib/supabase/server'

export type BackofficeRole = 'admin' | 'support'
export const BACKOFFICE_ROLES: BackofficeRole[] = ['admin', 'support']

export async function assertBackofficeRole(
  allowedRoles: BackofficeRole[] = BACKOFFICE_ROLES,
): Promise<{ userId: string; role: BackofficeRole }> {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')

  const role = user.app_metadata?.role as BackofficeRole | undefined
  if (!role || !allowedRoles.includes(role)) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }
  return { userId: user.id, role }
}
