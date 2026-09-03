'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

// ---------------------------------------------------------------------------
// Rols de backoffice de la plataforma (app_metadata.role al JWT de Supabase).
// Establerts server-side — l'usuari no els pot modificar.
//   'admin'   → accés total, totes les operacions permeses
//   'support' → lectura i operacions no destructives
// ---------------------------------------------------------------------------
type BackofficeRole = 'admin' | 'support'

const BACKOFFICE_ROLES: BackofficeRole[] = ['admin', 'support']

// ---------------------------------------------------------------------------
// assertAdmin — guard que s'ha de cridar al principi de cada Server Action.
// Valida el JWT contra Supabase Auth i comprova que app_metadata.role sigui
// un rol de backoffice reconegut. Opcionalment limita a rols específics.
//
// Exemples:
//   await assertAdmin()                    → accepta 'admin' i 'support'
//   await assertAdmin(['admin'])           → accepta només 'admin' (operacions destructives)
// ---------------------------------------------------------------------------
async function assertAdmin(allowedRoles: BackofficeRole[] = BACKOFFICE_ROLES) {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()

  if (error || !user) {
    throw new Error('Unauthenticated')
  }

  const role = user.app_metadata?.role as BackofficeRole | undefined

  if (!role || !allowedRoles.includes(role)) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }

  return { user, role }
}

// ---------------------------------------------------------------------------
// updateTenant — actualitza el nom, slug o estat arxivat d'un tenant.
//
// Exemple d'ús des d'un Server Component o form action:
//
//   import { updateTenant } from '@/app/admin/actions/tenants'
//
//   await updateTenant('uuid-del-tenant', { name: 'Nou Nom', archived: false })
// ---------------------------------------------------------------------------
// updateTenant — ambdós rols poden actualitzar (admin i support)
export async function updateTenant(
  tenantId: string,
  data: {
    name?: string
    slug?: string
    is_active?: boolean
  },
) {
  await assertAdmin() // accepta 'admin' i 'support'

  const updated = await prisma.tenants.update({
    where: { id: tenantId },
    data: {
      ...data,
      updated_at: new Date(),
    },
  })

  revalidatePath('/dashboard/tenants')
  return updated
}

// ---------------------------------------------------------------------------
// archiveTenant — operació destructiva: només 'admin'
export async function archiveTenant(tenantId: string, archive: boolean): Promise<void> {
  await assertAdmin(['admin']) // només superadmin pot arxivar
  await updateTenant(tenantId, { is_active: !archive })
}

// ---------------------------------------------------------------------------
// togglePublicPortal — activa o desactiva el mòdul de portal públic per a
// un tenant. Registra l'acció a data.audit_logs.
//
// Acció d'audit:
//   TENANT_PUBLIC_PORTAL_ENABLED  → quan s'activa
//   TENANT_PUBLIC_PORTAL_DISABLED → quan es desactiva
//
// Ús:
//   await togglePublicPortal(tenantId, true)   // activa
//   await togglePublicPortal(tenantId, false)  // desactiva
// ---------------------------------------------------------------------------
export async function togglePublicPortal(tenantId: string, enable: boolean): Promise<void> {
  const { user } = await assertAdmin(['admin'])

  await prisma.$transaction(async (tx) => {
    if (enable) {
      await tx.$executeRaw`
        SELECT data.ensure_portal_channel_granted(${tenantId}::uuid, 'public_portal')
      `
    }

    await tx.tenants.update({
      where: { id: tenantId },
      data: {
        public_portal_enabled: enable,
        updated_at: new Date(),
      },
    })

    await tx.$executeRaw`
      INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
      VALUES (
        ${tenantId}::uuid,
        ${user.id}::uuid,
        ${enable ? 'TENANT_PUBLIC_PORTAL_ENABLED' : 'TENANT_PUBLIC_PORTAL_DISABLED'},
        'tenant',
        ${tenantId}::uuid,
        ${JSON.stringify({ enabled: enable, changed_by: user.email })}::jsonb
      )
    `
  })

  revalidatePath('/dashboard/public-portal')
  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// createTenant — crea un tenant nou AMB el site inicial de forma atòmica.
// Crida data.provision_tenant() que executa els dos INSERTs en una sola
// transacció SQL → si qualsevol dels dos falla, tot fa rollback.
export async function createTenant(data: {
  name: string
  slug: string
  plan_id: string
}): Promise<{ id: string }> {
  await assertAdmin(['admin'])

  // provision_tenant retorna jsonb { tenant_id, site_id }
  type ProvisionResult = Array<{ provision_tenant: { tenant_id: string; site_id: string } | string }>
  const result = await prisma.$queryRaw<ProvisionResult>`
    SELECT data.provision_tenant(
      ${data.name.trim()},
      ${data.slug.trim().toLowerCase()},
      ${data.plan_id}::uuid
    ) AS provision_tenant
  `

  const raw = result[0].provision_tenant
  const parsed: { tenant_id: string; site_id: string } =
    typeof raw === 'string' ? JSON.parse(raw) : raw

  revalidatePath('/dashboard')
  return { id: parsed.tenant_id }
}

// ---------------------------------------------------------------------------
// AuditLogRow — tipus retornat per getAuditLogs
// ---------------------------------------------------------------------------
export interface AuditLogRow {
  id:          string
  action:      string
  entity_type: string | null
  entity_id:   string | null
  payload:     Record<string, unknown> | null
  created_at:  string
  user_email:  string | null
  user_name:   string | null
  site_id:     string | null
}

// ---------------------------------------------------------------------------
// getAuditLogs — retorna els últims registres d'auditoria d'un tenant
// ---------------------------------------------------------------------------
export async function getAuditLogs(
  tenantId: string,
  limit = 100,
  offset = 0,
): Promise<AuditLogRow[]> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<
    Array<{
      id:          string
      action:      string
      entity_type: string | null
      entity_id:   string | null
      payload:     unknown
      created_at:  Date
      user_email:  string | null
      user_name:   string | null
      site_id:     string | null
    }>
  >`
    SELECT
      al.id::text          AS id,
      al.action,
      al.entity_type,
      al.entity_id::text   AS entity_id,
      al.payload,
      al.created_at,
      p.email              AS user_email,
      p.full_name          AS user_name,
      al.site_id::text     AS site_id
    FROM data.audit_logs al
    LEFT JOIN data.profiles p ON p.id = al.user_id
    WHERE al.tenant_id = ${tenantId}::uuid
    ORDER BY al.created_at DESC
    LIMIT ${limit}
    OFFSET ${offset}
  `

  return rows.map((r) => ({
    id:          r.id,
    action:      r.action,
    entity_type: r.entity_type,
    entity_id:   r.entity_id,
    payload:     r.payload as Record<string, unknown> | null,
    created_at:  r.created_at.toISOString(),
    user_email:  r.user_email,
    user_name:   r.user_name,
    site_id:     r.site_id,
  }))
}
