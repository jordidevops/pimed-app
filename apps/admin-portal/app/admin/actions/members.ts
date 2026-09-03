'use server'

import { revalidatePath } from 'next/cache'
import { prisma } from '@/lib/prisma'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { createSupabaseAdminClient } from '@/lib/supabase/admin'

const VALID_MEMBER_ROLES = ['owner', 'manager', 'member', 'viewer'] as const
type ValidMemberRole = typeof VALID_MEMBER_ROLES[number]

function assertValidMemberRole(role: string): asserts role is ValidMemberRole {
  if (!VALID_MEMBER_ROLES.includes(role as ValidMemberRole)) {
    throw new Error(`Rol invàlid: ${role}`)
  }
}

// ---------------------------------------------------------------------------
// Shared types — used by both server (page.tsx) and client (MembersTab.tsx)
// ---------------------------------------------------------------------------

export type TenantHealth = {
  has_active_owner: boolean
  active_members: number
  max_users: number
  is_over_quota: boolean
}

export type MemberRow = {
  id: string         // tenant_member.id
  userId: string
  email: string
  fullName: string | null
  role: string
  scope: 'global' | 'site'
  siteId: string | null
  siteName: string | null
  isActive: boolean
  joinedAt: string        // ISO string (serialisable for client components)
  isPending: boolean      // true when first_login_at IS NULL (app never accessed)
  firstLoginAt: string | null  // first real login recorded by the app — ISO string
  lastLoginAt: string | null   // last login recorded by the app — ISO string
  isLastOwner: boolean    // cannot be modified/removed
}

export type InviteAssignmentInput = {
  tenantId: string
  role: string
}

// Auth metadata fetched on-demand when a detail modal is opened
export type MemberAuthDetail = {
  authCreatedAt: string | null      // when the auth.users record was created
  emailConfirmedAt: string | null   // when the email was confirmed (invite accepted)
  phone: string | null
  providers: string[]               // e.g. ['email'], ['google']
  bannedUntil: string | null
}

// ---------------------------------------------------------------------------
// Internal auth guard — same pattern as tenants.ts
// ---------------------------------------------------------------------------
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

// ---------------------------------------------------------------------------
// provisionAndInviteMember
// 1. Invites user via Supabase Auth Admin (creates auth.users + sends email)
// 2. Upserts data.profiles + inserts data.tenant_members in a transaction
// Handles quota_exceeded and duplicate-member errors.
// ---------------------------------------------------------------------------
export async function provisionAndInviteMember(
  tenantId: string,
  email: string,
  role: string,
): Promise<{ userId: string }> {
  return provisionAndInviteMemberMultiTenant(email, [{ tenantId, role }])
}

export async function provisionAndInviteMemberMultiTenant(
  email: string,
  assignments: InviteAssignmentInput[],
): Promise<{ userId: string }> {
  await assertAdmin(['admin'])

  const normalizedEmail = email.toLowerCase().trim()
  if (!normalizedEmail) throw new Error("L'adreça de correu és obligatòria.")
  if (!assignments.length) throw new Error('Cal definir almenys una assignació de tenant.')

  const normalizedAssignments = assignments.map((a) => {
    assertValidMemberRole(a.role)
    return { tenantId: a.tenantId, role: a.role as ValidMemberRole }
  })

  // Deduplicate by tenant, keeping the last selected role.
  const assignmentMap = new Map<string, ValidMemberRole>()
  for (const a of normalizedAssignments) assignmentMap.set(a.tenantId, a.role)
  const dedupedAssignments = Array.from(assignmentMap.entries()).map(([tenantId, role]) => ({ tenantId, role }))

  const supabaseAdmin = createSupabaseAdminClient()
  const tenantPortalUrl = process.env.TENANT_PORTAL_URL ?? 'http://localhost:5173'
  const redirectTo = `${tenantPortalUrl}/auth/callback`

  let userId: string
  const { data, error } = await supabaseAdmin.auth.admin.inviteUserByEmail(
    normalizedEmail,
    { data: { lang: 'ca' }, redirectTo },
  )

  if (error) {
    if (!error.message?.toLowerCase().includes('already been registered')) {
      throw new Error(`Error en enviar la invitació: ${error.message}`)
    }

    const existingProfile = await prisma.profiles.findFirst({ where: { email: normalizedEmail } })
    if (!existingProfile) {
      throw new Error("Aquest correu ja té un compte però no té perfil. Contacta amb suport.")
    }
    userId = existingProfile.id

    const { error: linkError } = await supabaseAdmin.auth.admin.generateLink({
      type: 'magiclink',
      email: normalizedEmail,
      options: { redirectTo },
    })
    if (linkError) {
      console.error('Failed to send magic link after re-activating member:', linkError.message)
    }
  } else {
    userId = data.user.id
  }

  try {
    await prisma.$transaction(async (tx) => {
      await tx.profiles.upsert({
        where: { id: userId },
        update: {},
        create: { id: userId, email: normalizedEmail },
      })

      for (const assignment of dedupedAssignments) {
        await tx.$executeRaw`
          INSERT INTO data.tenant_members (tenant_id, user_id, role, is_active)
          VALUES (${assignment.tenantId}::uuid, ${userId}::uuid, ${assignment.role}, true)
          ON CONFLICT (tenant_id, user_id) WHERE site_id IS NULL
          DO UPDATE SET role = EXCLUDED.role, is_active = true
        `
      }
    })
  } catch (dbErr) {
    const msg = dbErr instanceof Error ? dbErr.message : String(dbErr)
    if (msg.includes('quota_exceeded')) {
      throw new Error("S'ha superat la quota d'usuaris del pla actual.")
    }
    throw dbErr
  }

  for (const assignment of dedupedAssignments) {
    revalidatePath(`/dashboard/tenants/${assignment.tenantId}`)
  }
  revalidatePath('/dashboard/tenants')

  return { userId }
}

// ---------------------------------------------------------------------------
// resendInvitation — re-sends the invite email for a truly pending user.
// If the user already confirmed their email (edge case: first_login_at was
// backfilled but they haven't used record_login yet), sends a magic link
// instead so they can just click and land on the dashboard.
// ---------------------------------------------------------------------------
export async function resendInvitation(
  email: string,
  tenantId: string,
): Promise<void> {
  await assertAdmin(['admin'])

  const supabaseAdmin = createSupabaseAdminClient()
  const normalizedEmail = email.toLowerCase().trim()
  const tenantPortalUrl = process.env.TENANT_PORTAL_URL ?? 'http://localhost:5173'
  const redirectTo = `${tenantPortalUrl}/auth/callback`

  const { error } = await supabaseAdmin.auth.admin.inviteUserByEmail(
    normalizedEmail,
    { data: { lang: 'ca' }, redirectTo },
  )

  if (error) {
    if (error.message?.toLowerCase().includes('already been registered')) {
      // User already confirmed their email — send a magic link instead.
      const { error: linkError } = await supabaseAdmin.auth.admin.generateLink({
        type: 'magiclink',
        email: normalizedEmail,
        options: { redirectTo },
      })
      if (linkError) {
        throw new Error(`Error en enviar l'accés: ${linkError.message}`)
      }
      revalidatePath(`/dashboard/tenants/${tenantId}`)
      return
    }
    throw new Error(`Error en reenviar la invitació: ${error.message}`)
  }

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// updateMemberRole — changes a member's role within the tenant
// The DB trigger trg_protect_last_owner will block demoting the last owner.
// ---------------------------------------------------------------------------
export async function updateMemberRole(
  memberId: string,
  newRole: string,
  tenantId: string,
): Promise<void> {
  await assertAdmin(['admin'])
  assertValidMemberRole(newRole)

  try {
    await prisma.tenant_members.update({
      where: { id: memberId },
      data: { role: newRole },
    })
  } catch (dbErr) {
    const msg = dbErr instanceof Error ? dbErr.message : String(dbErr)
    if (msg.includes('protect_last_owner') || msg.includes('last_owner')) {
      throw new Error("No es pot canviar el rol de l'últim propietari actiu.")
    }
    throw dbErr
  }

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// deactivateMember — sets is_active = false for a tenant_member record.
// The tenant_members row is kept for audit; the user loses access.
// The DB trigger trg_protect_last_owner will block removing the last owner.
// ---------------------------------------------------------------------------
export async function deactivateMember(
  memberId: string,
  tenantId: string,
): Promise<void> {
  await assertAdmin(['admin'])

  try {
    await prisma.tenant_members.update({
      where: { id: memberId },
      data: { is_active: false },
    })
  } catch (dbErr) {
    const msg = dbErr instanceof Error ? dbErr.message : String(dbErr)
    if (msg.includes('protect_last_owner') || msg.includes('last_owner')) {
      throw new Error("No es pot desactivar l'últim propietari actiu.")
    }
    throw dbErr
  }

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

export async function deactivateUserMemberships(
  tenantId: string,
  userId: string,
): Promise<void> {
  await assertAdmin(['admin'])

  try {
    await prisma.$executeRaw`
      UPDATE data.tenant_members
      SET is_active = false
      WHERE tenant_id = ${tenantId}::uuid
        AND user_id = ${userId}::uuid
        AND is_active = true
    `
  } catch (dbErr) {
    const msg = dbErr instanceof Error ? dbErr.message : String(dbErr)
    if (msg.includes('protect_last_owner') || msg.includes('last_owner')) {
      throw new Error("No es pot desactivar l'últim propietari actiu.")
    }
    throw dbErr
  }

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}

// ---------------------------------------------------------------------------
// getMemberDetail — fetches extra auth metadata for the detail modal.
// Called lazily when a member row is expanded, not on page load.
// ---------------------------------------------------------------------------
export async function getMemberDetail(userId: string): Promise<MemberAuthDetail> {
  await assertAdmin()

  const supabaseAdmin = createSupabaseAdminClient()
  const { data, error } = await supabaseAdmin.auth.admin.getUserById(userId)

  if (error || !data.user) {
    throw new Error(`No s'ha pogut obtenir la informació de l'usuari: ${error?.message ?? 'desconegut'}`)
  }

  const u = data.user
  return {
    authCreatedAt:    u.created_at         ? new Date(u.created_at).toISOString()          : null,
    emailConfirmedAt: u.email_confirmed_at ? new Date(u.email_confirmed_at).toISOString()  : null,
    phone:            u.phone ?? null,
    providers:        (u.identities ?? []).map((i) => i.provider),
    bannedUntil:      u.banned_until       ? new Date(u.banned_until).toISOString()        : null,
  }
}

// ---------------------------------------------------------------------------
// suspendUser — bans the user across the whole system (all tenants).
// Sets ban_duration in Supabase Auth (prevents login) and deactivates all
// tenant_member rows. Data is preserved; reversible via Supabase dashboard.
// ---------------------------------------------------------------------------
export async function suspendUser(userId: string, tenantId: string): Promise<void> {
  await assertAdmin(['admin'])

  const supabaseAdmin = createSupabaseAdminClient()

  // Ban in Supabase Auth — prevents any new logins across all tenants.
  const { error } = await supabaseAdmin.auth.admin.updateUserById(userId, {
    ban_duration: '87600h', // 10 years ≈ indefinite
  })
  if (error) {
    throw new Error(`Error en suspendre l'usuari: ${error.message}`)
  }

  // Deactivate from every tenant (soft-delete of memberships).
  try {
    await prisma.tenant_members.updateMany({
      where: { user_id: userId, is_active: true },
      data: { is_active: false },
    })
  } catch (dbErr) {
    const msg = dbErr instanceof Error ? dbErr.message : String(dbErr)
    if (msg.includes('protect_last_owner') || msg.includes('last_owner')) {
      throw new Error(
        "No es pot suspendre: l'usuari és l'últim propietari actiu d'un o més tenants. Assigna un nou propietari prèviament.",
      )
    }
    throw dbErr
  }

  revalidatePath(`/dashboard/tenants/${tenantId}`)
}
