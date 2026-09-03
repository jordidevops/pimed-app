'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'

async function assertAdmin(allowedRoles: ('admin' | 'support')[] = ['admin', 'support']) {
  const supabase = await createSupabaseServerClient()
  const { data: { user }, error } = await supabase.auth.getUser()
  if (error || !user) throw new Error('Unauthenticated')
  const role = user.app_metadata?.role as string | undefined
  if (!role || !allowedRoles.includes(role as 'admin' | 'support')) {
    throw new Error(`Forbidden: requires one of [${allowedRoles.join(', ')}]`)
  }
  return { user, role }
}

export type PortalChannelEntitlements = {
  included_granted?: boolean
  included_plan?: boolean
  included_by_plan: boolean
  enabled_by_tenant: boolean
  effective: boolean
  cms_tier: string
  cms_tier_granted?: string
  cms_tier_plan?: string
  max_pages?: number
  max_pages_granted?: number
  max_pages_plan?: number
  pages_used_by_site?: Record<string, number>
}

export type CustomerPortalEntitlements = {
  included_granted?: boolean
  included_plan?: boolean
  enabled_by_tenant: boolean
  enabled_by_platform: boolean
  effective: boolean
  mode_granted?: string
  mode_plan?: string
  mode_effective?: string
  platform_max_mode?: string
  can_create_shares?: boolean
  can_grant_portal_access?: boolean
  customer_users_limit?: number | null
  active_share_guardrail?: number
  customer_mau_alert_threshold?: number
  included_email_deliveries_month?: number
  security_version_tenant?: number
  security_version_platform?: number
  new_share_policy?: 'allow' | 'blocked' | string
  new_access_policy?: 'allow' | 'review' | 'blocked' | string
  existing_access_policy?: 'allow' | 'blocked' | string
  restriction_reason?: string | null
  restriction_note?: string | null
}

export type PortalEntitlements = {
  tenant_id: string
  tenant_portal_entitlements?: TenantPortalEntitlementsSnapshot
  employee_portal: PortalChannelEntitlements
  public_portal: PortalChannelEntitlements
  customer_portal: CustomerPortalEntitlements
}

export type TenantPortalEntitlementsSnapshot = {
  employee_portal?: {
    included?: boolean
    cms_tier?: string
  }
  public_portal?: {
    included?: boolean
    cms_tier?: string
    max_pages?: number
  }
  customer_portal?: {
    included?: boolean
    mode?: 'share_only' | 'portal' | string
    active_share_guardrail?: number
    customer_mau_alert_threshold?: number
    included_email_deliveries_month?: number
    customer_users_limit?: number | null
  }
}

export type CustomerPortalPlatformState = {
  id: boolean
  enabled: boolean
  security_version: number
  max_mode: 'share_only' | 'portal' | string
  updated_at?: string
  updated_by?: string | null
  note?: string | null
}

export async function getPortalEntitlements(tenantId: string): Promise<PortalEntitlements> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<Array<{ resolve_portal_entitlements: PortalEntitlements }>>`
    SELECT data.resolve_portal_entitlements(${tenantId}::uuid) AS resolve_portal_entitlements
  `
  return rows[0]?.resolve_portal_entitlements
}

export async function getTenantPortalSnapshot(
  tenantId: string,
): Promise<TenantPortalEntitlementsSnapshot> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<Array<{ tenant_portal_entitlements: TenantPortalEntitlementsSnapshot }>>`
    SELECT tenant_portal_entitlements
    FROM data.tenants
    WHERE id = ${tenantId}::uuid
  `
  return rows[0]?.tenant_portal_entitlements ?? {}
}

export async function toggleEmployeePortal(tenantId: string, enable: boolean): Promise<void> {
  const { user } = await assertAdmin(['admin'])

  await prisma.$transaction(async (tx) => {
    if (enable) {
      await tx.$executeRaw`
        SELECT data.ensure_portal_channel_granted(${tenantId}::uuid, 'employee_portal')
      `
    }

    await tx.$executeRaw`
      UPDATE data.tenants
      SET employee_portal_enabled = ${enable}, updated_at = now()
      WHERE id = ${tenantId}::uuid
    `

    await tx.$executeRaw`
      INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
      VALUES (
        ${tenantId}::uuid,
        ${user.id}::uuid,
        ${enable ? 'TENANT_EMPLOYEE_PORTAL_ENABLED' : 'TENANT_EMPLOYEE_PORTAL_DISABLED'},
        'tenant',
        ${tenantId}::uuid,
        ${JSON.stringify({ enabled: enable, changed_by: user.email })}::jsonb
      )
    `
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
  revalidatePath('/dashboard/public-portal')
}

export async function toggleCustomerPortalTenant(
  tenantId: string,
  enable: boolean,
  note?: string,
): Promise<void> {
  const { user } = await assertAdmin(['admin'])

  await prisma.$transaction(async (tx) => {
    if (enable) {
      await tx.$executeRaw`
        SELECT data.ensure_portal_channel_granted(${tenantId}::uuid, 'customer_portal')
      `
    }

    await tx.$executeRaw`
      SELECT data.set_customer_portal_kill_switch(
        'tenant',
        ${tenantId}::uuid,
        ${enable},
        ${note ?? null}
      )
    `

    await tx.$executeRaw`
      INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
      VALUES (
        ${tenantId}::uuid,
        ${user.id}::uuid,
        ${enable ? 'TENANT_CUSTOMER_PORTAL_ENABLED' : 'TENANT_CUSTOMER_PORTAL_DISABLED'},
        'tenant',
        ${tenantId}::uuid,
        ${JSON.stringify({ enabled: enable, note: note ?? null, changed_by: user.email })}::jsonb
      )
    `
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
  revalidatePath('/dashboard/settings/customer-portal')
}

export async function setCustomerPortalTenantPolicies(
  tenantId: string,
  policies: {
    new_share_policy?: 'allow' | 'blocked' | null
    new_access_policy?: 'allow' | 'review' | 'blocked' | null
    existing_access_policy?: 'allow' | 'blocked' | null
    note?: string | null
  },
): Promise<void> {
  const { user } = await assertAdmin(['admin'])

  await prisma.$transaction(async (tx) => {
    await tx.$executeRaw`
      SELECT data.set_customer_portal_tenant_policies(
        ${tenantId}::uuid,
        ${policies.new_share_policy ?? null},
        ${policies.new_access_policy ?? null},
        ${policies.existing_access_policy ?? null},
        ${policies.note ?? null}
      )
    `

    await tx.$executeRaw`
      INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
      VALUES (
        ${tenantId}::uuid,
        ${user.id}::uuid,
        'TENANT_CUSTOMER_PORTAL_POLICIES_UPDATED',
        'tenant',
        ${tenantId}::uuid,
        ${JSON.stringify({
          new_share_policy: policies.new_share_policy ?? null,
          new_access_policy: policies.new_access_policy ?? null,
          existing_access_policy: policies.existing_access_policy ?? null,
          note: policies.note ?? null,
          changed_by: user.email,
        })}::jsonb
      )
    `
  })

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

export async function getCustomerPortalPlatformState(): Promise<CustomerPortalPlatformState> {
  await assertAdmin()

  const rows = await prisma.$queryRaw<
    Array<{ get_customer_portal_platform_state: CustomerPortalPlatformState }>
  >`
    SELECT data.get_customer_portal_platform_state() AS get_customer_portal_platform_state
  `
  const state = rows[0]?.get_customer_portal_platform_state
  if (!state) {
    throw new Error('customer_portal_platform_state not found')
  }
  return state
}

export async function setCustomerPortalPlatformEnabled(
  enabled: boolean,
  note?: string,
): Promise<CustomerPortalPlatformState> {
  const { user } = await assertAdmin(['admin'])

  const rows = await prisma.$queryRaw<
    Array<{ set_customer_portal_kill_switch: CustomerPortalPlatformState }>
  >`
    SELECT data.set_customer_portal_kill_switch(
      'platform',
      NULL::uuid,
      ${enabled},
      ${note ?? null}
    ) AS set_customer_portal_kill_switch
  `

  await prisma.$executeRaw`
    INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
    VALUES (
      NULL,
      ${user.id}::uuid,
      ${enabled ? 'PLATFORM_CUSTOMER_PORTAL_ENABLED' : 'PLATFORM_CUSTOMER_PORTAL_DISABLED'},
      'platform',
      NULL,
      ${JSON.stringify({ enabled, note: note ?? null, changed_by: user.email })}::jsonb
    )
  `

  revalidatePath('/dashboard/settings/customer-portal')

  const state = rows[0]?.set_customer_portal_kill_switch
  if (!state) {
    throw new Error('set_customer_portal_kill_switch returned empty')
  }
  return state
}

export async function setCustomerPortalPlatformMaxMode(
  max_mode: 'share_only' | 'portal',
  note?: string,
): Promise<CustomerPortalPlatformState> {
  const { user } = await assertAdmin(['admin'])

  const rows = await prisma.$queryRaw<
    Array<{ set_customer_portal_platform_max_mode: CustomerPortalPlatformState }>
  >`
    SELECT data.set_customer_portal_platform_max_mode(
      ${max_mode},
      ${note ?? null}
    ) AS set_customer_portal_platform_max_mode
  `

  await prisma.$executeRaw`
    INSERT INTO data.audit_logs (tenant_id, user_id, action, entity_type, entity_id, payload)
    VALUES (
      NULL,
      ${user.id}::uuid,
      'PLATFORM_CUSTOMER_PORTAL_MAX_MODE_UPDATED',
      'platform',
      NULL,
      ${JSON.stringify({ max_mode, note: note ?? null, changed_by: user.email })}::jsonb
    )
  `

  revalidatePath('/dashboard/settings/customer-portal')

  const state = rows[0]?.set_customer_portal_platform_max_mode
  if (!state) {
    throw new Error('set_customer_portal_platform_max_mode returned empty')
  }
  return state
}

export async function upsertTenantPortalEntitlements(
  tenantId: string,
  snapshot: TenantPortalEntitlementsSnapshot,
): Promise<PortalEntitlements> {
  await assertAdmin(['admin'])

  const rows = await prisma.$queryRaw<Array<{ upsert_tenant_portal_entitlements: PortalEntitlements }>>`
    SELECT data.upsert_tenant_portal_entitlements(
      ${tenantId}::uuid,
      ${JSON.stringify(snapshot)}::jsonb
    ) AS upsert_tenant_portal_entitlements
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)

  return rows[0]?.upsert_tenant_portal_entitlements
}

/** @deprecated TCMS-1.1 — usar upsertTenantPortalEntitlements */
export async function upsertTenantPortalOverrides(
  tenantId: string,
  overrides: {
    employee_portal?: { cms_tier?: string | null }
    public_portal?: { cms_tier?: string | null }
  },
): Promise<void> {
  const payload: TenantPortalEntitlementsSnapshot = {}
  if (overrides.employee_portal?.cms_tier) {
    payload.employee_portal = { cms_tier: overrides.employee_portal.cms_tier }
  }
  if (overrides.public_portal?.cms_tier) {
    payload.public_portal = { cms_tier: overrides.public_portal.cms_tier }
  }
  await upsertTenantPortalEntitlements(tenantId, payload)
}

export async function syncPortalEntitlementsWithPlan(tenantId: string): Promise<PortalEntitlements> {
  await assertAdmin(['admin'])

  const rows = await prisma.$queryRaw<Array<{ sync_portal_entitlements_with_plan: PortalEntitlements }>>`
    SELECT data.sync_portal_entitlements_with_plan(${tenantId}::uuid) AS sync_portal_entitlements_with_plan
  `

  revalidatePath(`/dashboard/tenants/${tenantId}`)

  return rows[0]?.sync_portal_entitlements_with_plan
}

export interface PlanPortalRow {
  id: string
  name: string
  display_name: string
  max_portal_pages: number
  portal_entitlements: Record<string, unknown>
}

export async function listPlansWithPortalEntitlements(): Promise<PlanPortalRow[]> {
  await assertAdmin()

  return prisma.$queryRaw<PlanPortalRow[]>`
    SELECT
      id::text,
      name,
      display_name,
      max_portal_pages,
      portal_entitlements
    FROM data.plans
    ORDER BY price_monthly ASC
  `
}

export async function updatePlanPortalEntitlements(
  planId: string,
  entitlements: Record<string, unknown>,
): Promise<void> {
  await assertAdmin(['admin'])

  await prisma.$executeRaw`
    UPDATE data.plans
    SET portal_entitlements = ${JSON.stringify(entitlements)}::jsonb,
        updated_at = now()
    WHERE id = ${planId}::uuid
  `

  revalidatePath('/dashboard/plans')
}
