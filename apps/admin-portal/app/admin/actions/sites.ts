'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

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

export interface SiteRow {
  id:         string
  tenant_id:  string
  name:       string
  address:    string | null
  is_active:  boolean
  created_at: Date
}

// ---------------------------------------------------------------------------
// getSitesForTenant — retorna tots els sites (actius + inactius) d'un tenant.
// Usat pel superadmin per veure el llistat complet.
// ---------------------------------------------------------------------------
export async function getSitesForTenant(tenantId: string): Promise<SiteRow[]> {
  await assertAdmin()
  return prisma.$queryRaw<SiteRow[]>`
    SELECT id, tenant_id, name, address, is_active, created_at
    FROM data.sites
    WHERE tenant_id = ${tenantId}::uuid
    ORDER BY name ASC
  `
}

// ---------------------------------------------------------------------------
// createSiteForTenant — crea un site nou per a un tenant.
// El superadmin bypassa el trigger enforce_site_quota perquè Prisma connecta
// via service_role (current_role = 'authenticator' → 'service_role' BYPASSRLS).
// ---------------------------------------------------------------------------
export async function createSiteForTenant(
  tenantId: string,
  name: string,
  address: string | null,
): Promise<void> {
  await assertAdmin(['admin'])

  if (!name.trim()) throw new Error('El nom del site és obligatori.')

  await prisma.$executeRaw`
    INSERT INTO data.sites (tenant_id, name, address)
    VALUES (${tenantId}::uuid, ${name.trim()}, ${address ?? null})
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// updateSite — edita nom i/o adreça d'un site existent.
// ---------------------------------------------------------------------------
export async function updateSite(
  siteId: string,
  tenantId: string,
  data: { name?: string; address?: string | null },
): Promise<void> {
  await assertAdmin(['admin'])

  if (data.name !== undefined && !data.name.trim()) {
    throw new Error('El nom del site és obligatori.')
  }

  await prisma.$executeRaw`
    UPDATE data.sites
    SET
      name       = COALESCE(${data.name?.trim() ?? null}, name),
      address    = ${data.address !== undefined ? (data.address ?? null) : null},
      updated_at = now()
    WHERE id = ${siteId}::uuid
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// toggleSiteActive — activa o desactiva un site.
// Desactivar un site no elimina les dades; el site queda ocult als usuaris.
// ---------------------------------------------------------------------------
export async function toggleSiteActive(
  siteId: string,
  tenantId: string,
  active: boolean,
): Promise<void> {
  await assertAdmin(['admin'])

  await prisma.$executeRaw`
    UPDATE data.sites
    SET is_active = ${active}, updated_at = now()
    WHERE id = ${siteId}::uuid
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}
