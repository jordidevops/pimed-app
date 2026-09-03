'use server'

import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'

type BackofficeRole = 'admin' | 'support'

async function assertAdmin(allowedRoles: BackofficeRole[] = ['admin', 'support']) {
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
  return { user, role }
}

function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase()
}

export type CustomerGrantRow = {
  id: string
  tenantId: string
  tenantName: string
  authUserId: string
  email: string
  principalKind: string
  accountContactId: string
  accountName: string | null
  principalContactId: string
  principalName: string | null
  isActive: boolean
  lastSeenAt: string | null
  createdAt: string
  revokedAt: string | null
}

export type TenantMemberHit = {
  tenantId: string
  tenantName: string
  role: string
  isActive: boolean
  joinedAt: string | null
}

export type CustomerGrantHit = {
  grantId: string
  tenantId: string
  tenantName: string
  principalKind: string
  accountName: string | null
  isActive: boolean
  lastSeenAt: string | null
  createdAt: string
}

export type ShareHit = {
  shareId: string
  tenantId: string
  tenantName: string
  channel: string
  expiresAt: string
  revokedAt: string | null
  isActive: boolean
  sessionCount: number
  viewCount: number
  projectId: string | null
  reportVersionId: string | null
  recipientEmail: string | null
}

export type EmailIdentityLookup = {
  email: string
  authUserId: string | null
  authEmail: string | null
  profileId: string | null
  profileFullName: string | null
  appMetadataCustomerPortal: boolean
  isBackoffice: boolean
  tenantMemberships: TenantMemberHit[]
  customerGrants: CustomerGrantHit[]
  pendingInvitations: Array<{
    invitationId: string
    tenantId: string
    tenantName: string
    expiresAt: string
    principalKind: string
    accountName: string | null
  }>
  bulletinShares: ShareHit[]
}

export async function listCustomerGrantsForTenant(
  tenantId: string,
  opts?: { onlyActive?: boolean; limit?: number },
): Promise<CustomerGrantRow[]> {
  await assertAdmin()
  const onlyActive = opts?.onlyActive ?? false
  const limit = Math.min(Math.max(opts?.limit ?? 200, 1), 500)

  const rows = await prisma.$queryRaw<
    Array<{
      id: string
      tenant_id: string
      tenant_name: string
      auth_user_id: string
      email_normalized: string
      principal_kind: string
      client_account_contact_id: string
      account_name: string | null
      principal_contact_id: string
      principal_name: string | null
      revoked_at: Date | null
      last_seen_at: Date | null
      created_at: Date
    }>
  >`
    SELECT
      g.id,
      g.tenant_id,
      t.name AS tenant_name,
      g.auth_user_id::text AS auth_user_id,
      g.email_normalized,
      g.principal_kind,
      g.client_account_contact_id::text AS client_account_contact_id,
      acc.display_name AS account_name,
      g.principal_contact_id::text AS principal_contact_id,
      prin.display_name AS principal_name,
      g.revoked_at,
      g.last_seen_at,
      g.created_at
    FROM data.customer_access_grants g
    JOIN data.tenants t ON t.id = g.tenant_id
    LEFT JOIN data.contacts acc ON acc.id = g.client_account_contact_id
    LEFT JOIN data.contacts prin ON prin.id = g.principal_contact_id
    WHERE g.tenant_id = ${tenantId}::uuid
      AND (${onlyActive} = false OR g.revoked_at IS NULL)
    ORDER BY g.created_at DESC
    LIMIT ${limit}
  `

  return rows.map((r) => ({
    id: r.id,
    tenantId: r.tenant_id,
    tenantName: r.tenant_name,
    authUserId: r.auth_user_id,
    email: r.email_normalized,
    principalKind: r.principal_kind,
    accountContactId: r.client_account_contact_id,
    accountName: r.account_name,
    principalContactId: r.principal_contact_id,
    principalName: r.principal_name,
    isActive: r.revoked_at == null,
    lastSeenAt: r.last_seen_at?.toISOString() ?? null,
    createdAt: r.created_at.toISOString(),
    revokedAt: r.revoked_at?.toISOString() ?? null,
  }))
}

export async function lookupIdentityByEmail(emailRaw: string): Promise<EmailIdentityLookup> {
  await assertAdmin()
  const email = normalizeEmail(emailRaw)
  if (!email || !email.includes('@')) {
    throw new Error('Email invàlid')
  }

  // Prisma DB role cannot read auth.* — resolve identity via data.profiles + Auth Admin API.
  const profileRows = await prisma.$queryRaw<
    Array<{ id: string; email: string | null; full_name: string | null }>
  >`
    SELECT id::text AS id, email, full_name
    FROM data.profiles
    WHERE lower(btrim(COALESCE(email, ''))) = ${email}
    LIMIT 1
  `
  let profile = profileRows[0] ?? null

  // Grants / invites are keyed by email even without a profile yet.
  const grantProbe = await prisma.$queryRaw<Array<{ auth_user_id: string }>>`
    SELECT auth_user_id::text AS auth_user_id
    FROM data.customer_access_grants
    WHERE email_normalized = ${email}
    ORDER BY created_at DESC
    LIMIT 1
  `

  let authUserId = profile?.id ?? grantProbe[0]?.auth_user_id ?? null
  let authEmail: string | null = profile?.email ?? null
  let appMetadataCustomerPortal = false
  let isBackoffice = false

  if (authUserId) {
    try {
      const admin = createSupabaseAdminClient()
      const { data, error } = await admin.auth.admin.getUserById(authUserId)
      if (!error && data.user) {
        authEmail = data.user.email ?? authEmail
        const meta = (data.user.app_metadata ?? {}) as Record<string, unknown>
        appMetadataCustomerPortal = Boolean(meta.customer_portal)
        isBackoffice = meta.role === 'admin' || meta.role === 'support'
        if (!profile) {
          const byId = await prisma.$queryRaw<
            Array<{ id: string; email: string | null; full_name: string | null }>
          >`
            SELECT id::text AS id, email, full_name
            FROM data.profiles
            WHERE id = ${authUserId}::uuid
            LIMIT 1
          `
          profile = byId[0] ?? null
        }
      }
    } catch {
      // Auth Admin unavailable — continue with profile/grants only
    }
  }

  const tenantMemberships =
    authUserId == null
      ? []
      : (
          await prisma.$queryRaw<
            Array<{
              tenant_id: string
              tenant_name: string
              role: string
              is_active: boolean
              joined_at: Date | null
            }>
          >`
            SELECT
              tm.tenant_id::text AS tenant_id,
              t.name AS tenant_name,
              tm.role::text AS role,
              tm.is_active,
              tm.joined_at
            FROM data.tenant_members tm
            JOIN data.tenants t ON t.id = tm.tenant_id
            WHERE tm.user_id = ${authUserId}::uuid
            ORDER BY t.name
          `
        ).map((r) => ({
          tenantId: r.tenant_id,
          tenantName: r.tenant_name,
          role: r.role,
          isActive: r.is_active,
          joinedAt: r.joined_at?.toISOString() ?? null,
        }))

  const grantRows =
    authUserId == null
      ? await prisma.$queryRaw<
          Array<{
            grant_id: string
            tenant_id: string
            tenant_name: string
            principal_kind: string
            account_name: string | null
            revoked_at: Date | null
            last_seen_at: Date | null
            created_at: Date
          }>
        >`
          SELECT
            g.id::text AS grant_id,
            g.tenant_id::text AS tenant_id,
            t.name AS tenant_name,
            g.principal_kind,
            acc.display_name AS account_name,
            g.revoked_at,
            g.last_seen_at,
            g.created_at
          FROM data.customer_access_grants g
          JOIN data.tenants t ON t.id = g.tenant_id
          LEFT JOIN data.contacts acc ON acc.id = g.client_account_contact_id
          WHERE g.email_normalized = ${email}
          ORDER BY g.created_at DESC
        `
      : await prisma.$queryRaw<
          Array<{
            grant_id: string
            tenant_id: string
            tenant_name: string
            principal_kind: string
            account_name: string | null
            revoked_at: Date | null
            last_seen_at: Date | null
            created_at: Date
          }>
        >`
          SELECT
            g.id::text AS grant_id,
            g.tenant_id::text AS tenant_id,
            t.name AS tenant_name,
            g.principal_kind,
            acc.display_name AS account_name,
            g.revoked_at,
            g.last_seen_at,
            g.created_at
          FROM data.customer_access_grants g
          JOIN data.tenants t ON t.id = g.tenant_id
          LEFT JOIN data.contacts acc ON acc.id = g.client_account_contact_id
          WHERE g.email_normalized = ${email}
             OR g.auth_user_id = ${authUserId}::uuid
          ORDER BY g.created_at DESC
        `

  const customerGrants = grantRows.map((r) => ({
    grantId: r.grant_id,
    tenantId: r.tenant_id,
    tenantName: r.tenant_name,
    principalKind: r.principal_kind,
    accountName: r.account_name,
    isActive: r.revoked_at == null,
    lastSeenAt: r.last_seen_at?.toISOString() ?? null,
    createdAt: r.created_at.toISOString(),
  }))

  const pendingInvitations = (
    await prisma.$queryRaw<
      Array<{
        invitation_id: string
        tenant_id: string
        tenant_name: string
        expires_at: Date
        principal_kind: string
        account_name: string | null
      }>
    >`
      SELECT
        i.id::text AS invitation_id,
        i.tenant_id::text AS tenant_id,
        t.name AS tenant_name,
        i.expires_at,
        i.principal_kind,
        acc.display_name AS account_name
      FROM data.customer_access_invitations i
      JOIN data.tenants t ON t.id = i.tenant_id
      LEFT JOIN data.contacts acc ON acc.id = i.client_account_contact_id
      WHERE i.email_normalized = ${email}
        AND i.accepted_at IS NULL
        AND i.revoked_at IS NULL
      ORDER BY i.created_at DESC
    `
  ).map((r) => ({
    invitationId: r.invitation_id,
    tenantId: r.tenant_id,
    tenantName: r.tenant_name,
    expiresAt: r.expires_at.toISOString(),
    principalKind: r.principal_kind,
    accountName: r.account_name,
  }))

  const bulletinShares = (
    await prisma.$queryRaw<
      Array<{
        share_id: string
        tenant_id: string
        tenant_name: string
        channel: string
        expires_at: Date
        revoked_at: Date | null
        session_count: number
        view_count: number
        project_id: string | null
        report_version_id: string | null
        recipient_email: string | null
      }>
    >`
      SELECT
        s.id::text AS share_id,
        s.tenant_id::text AS tenant_id,
        t.name AS tenant_name,
        s.channel,
        s.expires_at,
        s.revoked_at,
        s.session_count,
        s.view_count,
        s.project_id::text AS project_id,
        s.report_version_id::text AS report_version_id,
        COALESCE(ch.value_normalized, lower(btrim(rc.email))) AS recipient_email
      FROM data.customer_report_shares s
      JOIN data.tenants t ON t.id = s.tenant_id
      LEFT JOIN data.contact_delivery_channels ch ON ch.id = s.delivery_channel_id
      LEFT JOIN data.contacts rc ON rc.id = s.recipient_contact_id
      WHERE lower(btrim(COALESCE(ch.value_normalized, ''))) = ${email}
         OR lower(btrim(COALESCE(rc.email, ''))) = ${email}
      ORDER BY s.created_at DESC
      LIMIT 100
    `
  ).map((r) => ({
    shareId: r.share_id,
    tenantId: r.tenant_id,
    tenantName: r.tenant_name,
    channel: r.channel,
    expiresAt: r.expires_at.toISOString(),
    revokedAt: r.revoked_at?.toISOString() ?? null,
    isActive: r.revoked_at == null && r.expires_at.getTime() > Date.now(),
    sessionCount: Number(r.session_count ?? 0),
    viewCount: Number(r.view_count ?? 0),
    projectId: r.project_id,
    reportVersionId: r.report_version_id,
    recipientEmail: r.recipient_email,
  }))

  return {
    email,
    authUserId,
    authEmail: authEmail ?? profile?.email ?? null,
    profileId: profile?.id ?? null,
    profileFullName: profile?.full_name ?? null,
    appMetadataCustomerPortal,
    isBackoffice,
    tenantMemberships,
    customerGrants,
    pendingInvitations,
    bulletinShares,
  }
}
