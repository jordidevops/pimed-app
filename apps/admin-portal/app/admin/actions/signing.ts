'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

type BackofficeRole = 'admin' | 'support'
const BACKOFFICE_ROLES: BackofficeRole[] = ['admin', 'support']

async function assertAdmin(allowedRoles: BackofficeRole[] = BACKOFFICE_ROLES) {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthorized')
  const role = user.app_metadata?.role as string | undefined
  if (!allowedRoles.includes(role as BackofficeRole)) throw new Error('Forbidden')
}

/**
 * Estableix els crèdits de signatura per a un tenant (mode platform).
 * Requereix rol 'admin'.
 */
export async function setTenantSigningCredits(
  tenantId: string,
  credits: number,
): Promise<void> {
  await assertAdmin(['admin'])
  if (!Number.isInteger(credits) || credits < 0)
    throw new Error('credits ha de ser un enter no negatiu')

  await prisma.$executeRaw`
    INSERT INTO data.tenant_signing_config (tenant_id, mode, signing_credits)
    VALUES (${tenantId}::uuid, 'platform', ${credits})
    ON CONFLICT (tenant_id) DO UPDATE
      SET signing_credits = ${credits},
          updated_at      = now()
  `
  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

/**
 * Activa o desactiva la desactivació forçada admin d'un tenant.
 * Quan admin_disabled=true, el tenant NO pot signar independentment del seu is_active.
 *
 * Requereix rol 'admin' (operació sensible).
 * Fa un upsert: si no existeix fila, la crea amb is_active=false i admin_disabled=true.
 */
export async function setTenantSigningAdminDisabled(
  tenantId: string,
  disabled: boolean,
): Promise<void> {
  await assertAdmin(['admin'])

  await prisma.$executeRaw`
    INSERT INTO data.tenant_signing_config (tenant_id, mode, is_active, admin_disabled)
    VALUES (${tenantId}::uuid, 'platform', false, ${disabled})
    ON CONFLICT (tenant_id) DO UPDATE
      SET admin_disabled = ${disabled},
          updated_at     = now()
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}
