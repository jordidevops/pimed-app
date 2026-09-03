import { supabase } from '@/lib/supabase'
import { getFunctionErrorMessage, getResponseErrorMessage } from '@/lib/functionErrors'
import {
  generatePortalSecret,
  hashPortalPin,
  hashPortalSecretForRpc,
  isValidPortalPin,
} from '../utils/portalCrypto'
import type {
  CreateEmployeePortalTokenInput,
  CreateEmployeePortalTokenResult,
  EmployeePortalAccessLog,
  EmployeePortalToken,
} from './employeePortalTypes'

export type EmployeePortalErrorCode =
  | 'duplicate_active_label'
  | 'employee_not_active'
  | 'employee_missing_document_id'
  | 'invalid_pin'
  | 'unauthorized'
  | 'generic'

export function normalizeEmployeePortalError(error: unknown): EmployeePortalErrorCode {
  const message =
    typeof error === 'object' && error !== null && 'message' in error
      ? String((error as { message?: string }).message ?? '')
      : ''

  if (message.includes('duplicate_active_label') || message.includes('23505')) {
    return 'duplicate_active_label'
  }
  if (message.includes('employee_not_active')) return 'employee_not_active'
  if (message.includes('employee_missing_document_id')) return 'employee_missing_document_id'
  if (message.includes('insufficient_privilege') || message.includes('42501')) {
    return 'unauthorized'
  }
  return 'generic'
}

export async function listEmployeePortalTokens(
  employeeId: string,
): Promise<EmployeePortalToken[]> {
  const { data, error } = await supabase.rpc('list_employee_portal_tokens', {
    p_employee_id: employeeId,
  })
  if (error) throw error
  return (data as EmployeePortalToken[] | null) ?? []
}

export async function listEmployeePortalAccessLogs(
  tokenId: string,
  limit = 50,
): Promise<EmployeePortalAccessLog[]> {
  const { data, error } = await supabase.rpc('list_employee_portal_access_logs', {
    p_token_id: tokenId,
    p_limit: limit,
  })
  if (error) throw error
  return (data as EmployeePortalAccessLog[] | null) ?? []
}

export async function createEmployeePortalToken(
  input: CreateEmployeePortalTokenInput,
): Promise<CreateEmployeePortalTokenResult> {
  if (input.pin && !isValidPortalPin(input.pin)) {
    throw new Error('invalid_pin')
  }

  const secret = generatePortalSecret()
  const tokenHash = await hashPortalSecretForRpc(secret)
  const pinHash = input.pin ? await hashPortalPin(input.pin) : null
  const pinMustSet =
    input.pin != null
      ? false
      : input.pinRequired === false
        ? false
        : (input.pinMustSet ?? true)

  const { data, error } = await supabase.rpc('create_employee_portal_token', {
    p_employee_id: input.employeeId,
    p_token_hash: tokenHash,
    p_label: input.label?.trim() || undefined,
    p_pin_hash: pinHash ?? undefined,
    p_pin_must_set: pinMustSet,
    p_expires_at: input.expiresAt || undefined,
  })

  if (error) throw error

  const tokenId = (data as { token_id?: string } | null)?.token_id
  if (!tokenId) throw new Error('missing_token_id')

  const supersededTokenId =
    (data as { superseded_token_id?: string | null } | null)?.superseded_token_id ?? null

  return { tokenId, secret, supersededTokenId }
}

export interface RequestEmployeePortalPinResetResult {
  resetId: string
  secret: string
  expiresAt: string
}

export async function requestEmployeePortalPinReset(
  tokenId: string,
): Promise<RequestEmployeePortalPinResetResult> {
  const secret = generatePortalSecret()
  const resetTokenHash = await hashPortalSecretForRpc(secret)

  const { data, error } = await supabase.rpc('create_employee_portal_pin_reset', {
    p_employee_portal_token_id: tokenId,
    p_reset_token_hash: resetTokenHash,
  })

  if (error) throw error

  const resetId = (data as { reset_id?: string } | null)?.reset_id
  const expiresAt = (data as { expires_at?: string } | null)?.expires_at
  if (!resetId || !expiresAt) throw new Error('missing_pin_reset_payload')

  return { resetId, secret, expiresAt }
}

export interface SendEmployeePortalAccessEmailInput {
  tenantId: string
  employeeId: string
  tokenId: string
  secret: string
  recipient?: string
  locale?: string
}

export interface SendEmployeePortalAccessEmailResult {
  emailLogId: string
  portalUrl: string
  recipient: string
  recipientOverride: boolean
}

export async function sendEmployeePortalAccessEmail(
  input: SendEmployeePortalAccessEmailInput,
): Promise<SendEmployeePortalAccessEmailResult> {
  const { data, error } = await supabase.functions.invoke('send-employee-portal-access-email', {
    headers: { 'x-tenant-id': input.tenantId },
    body: {
      tenant_id: input.tenantId,
      employee_id: input.employeeId,
      token_id: input.tokenId,
      secret: input.secret,
      recipient: input.recipient,
      locale: input.locale ?? 'ca',
    },
  })

  if (error) {
    const detailed = await getFunctionErrorMessage(error)
    throw new Error(detailed ?? error.message)
  }

  const responseError = getResponseErrorMessage(data)
  if (responseError) throw new Error(responseError)

  const payload = data as {
    email_log_id?: string
    portal_url?: string
    recipient?: string
    recipient_override?: boolean
  }

  if (!payload.email_log_id) throw new Error('missing_email_log_id')

  return {
    emailLogId: payload.email_log_id,
    portalUrl: payload.portal_url ?? '',
    recipient: payload.recipient ?? input.recipient ?? '',
    recipientOverride: payload.recipient_override ?? false,
  }
}

export async function revokeEmployeePortalToken(input: {
  tokenId: string
  reason?: string
  compromised?: boolean
}): Promise<void> {
  const { error } = await supabase.rpc('revoke_employee_portal_token', {
    p_token_id: input.tokenId,
    p_reason: input.reason?.trim() || undefined,
    p_compromised: input.compromised ?? false,
  })
  if (error) throw error
}
