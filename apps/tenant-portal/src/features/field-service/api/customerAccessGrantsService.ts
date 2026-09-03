import { supabase } from '@/lib/supabase'

export type CustomerAccessPrincipalKind = 'named_person' | 'shared_mailbox'

export type CustomerAccessInvitation = {
  id: string
  tenant_id: string
  client_account_contact_id: string
  principal_kind: CustomerAccessPrincipalKind
  principal_contact_id: string
  contact_relationship_id: string | null
  delivery_channel_id: string | null
  email_normalized: string
  invited_by: string | null
  expires_at: string
  accepted_at: string | null
  accepted_auth_user_id: string | null
  revoked_at: string | null
  revoked_by: string | null
  revoke_reason: string | null
  created_at: string
  is_pending: boolean | null
}

export type CustomerAccessGrant = {
  id: string
  tenant_id: string
  auth_user_id: string
  client_account_contact_id: string
  principal_kind: CustomerAccessPrincipalKind
  principal_contact_id: string
  email_normalized: string
  session_version: number
  invitation_id: string | null
  last_seen_at: string | null
  revoked_at: string | null
  revoked_by: string | null
  revoke_reason: string | null
  created_at: string
  updated_at: string
  is_active: boolean | null
}

export type CreateCustomerAccessInvitationResult = {
  invitation_id: string
  secret: string
  expires_at: string
  email_normalized: string
  accept_path: string
  accept_url: string
}

function customerPortalOrigin(): string {
  return (
    (import.meta.env.VITE_CUSTOMER_PORTAL_ORIGIN as string | undefined)?.replace(/\/$/, '') ?? ''
  )
}

/** Invite URL shown once at creation. Prefer local `/invite/` contract. */
export function customerPortalInviteUrl(secret: string): string {
  const base = customerPortalOrigin()
  if (!base) {
    throw new Error('VITE_CUSTOMER_PORTAL_ORIGIN is required to build invite URLs')
  }
  return `${base}/invite/${secret}`
}

export async function createCustomerAccessInvitation(params: {
  clientAccountContactId: string
  principalKind: CustomerAccessPrincipalKind
  principalContactId: string
  deliveryChannelId: string
  ttlHours?: number
}): Promise<CreateCustomerAccessInvitationResult> {
  const { data, error } = await supabase.rpc('create_customer_access_invitation' as never, {
    p_client_account_contact_id: params.clientAccountContactId,
    p_principal_kind: params.principalKind,
    p_principal_contact_id: params.principalContactId,
    p_delivery_channel_id: params.deliveryChannelId,
    p_ttl_hours: params.ttlHours ?? 72,
  } as never)
  if (error) throw error
  const result = data as Omit<CreateCustomerAccessInvitationResult, 'accept_url'>
  return {
    ...result,
    accept_url: customerPortalInviteUrl(result.secret),
  }
}

export async function listCustomerAccessInvitations(opts?: {
  clientAccountContactId?: string | null
  onlyPending?: boolean
}): Promise<CustomerAccessInvitation[]> {
  const { data, error } = await supabase.rpc('list_customer_access_invitations' as never, {
    p_client_account_contact_id: opts?.clientAccountContactId ?? null,
    p_only_pending: opts?.onlyPending ?? false,
  } as never)
  if (error) throw error
  return (data ?? []) as CustomerAccessInvitation[]
}

export async function listCustomerAccessGrants(opts?: {
  clientAccountContactId?: string | null
  onlyActive?: boolean
}): Promise<CustomerAccessGrant[]> {
  const { data, error } = await supabase.rpc('list_customer_access_grants' as never, {
    p_client_account_contact_id: opts?.clientAccountContactId ?? null,
    p_only_active: opts?.onlyActive ?? false,
  } as never)
  if (error) throw error
  return (data ?? []) as CustomerAccessGrant[]
}

export async function revokeCustomerAccessInvitation(
  invitationId: string,
  reason?: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('revoke_customer_access_invitation' as never, {
    p_invitation_id: invitationId,
    p_reason: reason ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export async function revokeCustomerAccessGrant(
  grantId: string,
  reason?: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('revoke_customer_access_grant' as never, {
    p_grant_id: grantId,
    p_reason: reason ?? null,
  } as never)
  if (error) throw error
  return data as string
}

export type CustomerPortalStaffSessionRow = {
  id: string
  staff_user_id: string
  staff_display_name: string
  staff_email: string | null
  scope_mode: string
  report_version_id: string | null
  created_at: string
  expires_at: string
  last_seen_at: string | null
  revoked_at: string | null
  exchanged_at: string | null
  is_active: boolean
}

export async function listCustomerPortalStaffSessionsForAccount(
  clientAccountContactId: string,
  limit = 30,
): Promise<CustomerPortalStaffSessionRow[]> {
  const { data, error } = await supabase.rpc(
    'list_customer_portal_staff_sessions_for_account' as never,
    {
      p_client_account_contact_id: clientAccountContactId,
      p_limit: limit,
    } as never,
  )
  if (error) throw error
  return (data ?? []) as CustomerPortalStaffSessionRow[]
}

/** Map known RPC error codes to i18n keys under settings.customer_portal.access.* */
export function customerAccessRpcErrorKey(message: string): string | null {
  const m = message.toLowerCase()
  if (m.includes('recipient_relationship_required') || m.includes('relationship_revoked')) {
    return 'customer_portal.access.errRelationship'
  }
  if (m.includes('delivery_channel_invalid') || m.includes('contact_delivery_rule_channel')) {
    return 'customer_portal.access.errChannel'
  }
  if (
    m.includes('shared_mailbox_must_be_account') ||
    m.includes('named_person_requires_person') ||
    m.includes('person_account_self_principal') ||
    m.includes('invalid_principal_kind')
  ) {
    return 'customer_portal.access.errPrincipal'
  }
  if (m.includes('customer_users_limit_reached')) {
    return 'customer_portal.access.errLimit'
  }
  if (m.includes('invitation_not_found') || m.includes('grant_not_found')) {
    return 'customer_portal.access.errNotFound'
  }
  if (
    m.includes('customer_portal_access_grants_not_allowed') ||
    m.includes('customer_portal_shares_not_allowed') ||
    m.includes('active_share_guardrail') ||
    m.includes('not_allowed') ||
    m.includes('blocked')
  ) {
    return 'customer_portal.access.errNotAllowed'
  }
  if (m.includes('contact_relationship_already_active')) {
    return 'customer_portal.access.errRelationshipActive'
  }
  if (m.includes('contacts_portal_manage_required')) {
    return 'customer_portal.access.errPermission'
  }
  return null
}
