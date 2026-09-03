export interface EmployeePortalToken {
  id: string
  tenant_id: string
  employee_id: string
  pin_required: boolean
  pin_must_set?: boolean
  pin_attempts: number
  pin_locked_until: string | null
  session_version: number
  compromised: boolean
  expires_at: string | null
  is_active: boolean
  label: string | null
  first_accessed_at: string | null
  last_accessed_at: string | null
  created_by_user_id: string | null
  created_at: string
  revoked_at: string | null
  revoke_reason: string | null
}

export interface EmployeePortalAccessLog {
  id: number
  token_id: string
  employee_id: string
  tenant_id: string
  accessed_at: string
  ip_address: string | null
  user_agent: string | null
  action: string
  http_status: number | null
  failure_reason: string | null
  metadata?: Record<string, unknown> | null
}

export interface CreateEmployeePortalTokenInput {
  employeeId: string
  label?: string
  pin?: string | null
  pinRequired?: boolean
  pinMustSet?: boolean
  expiresAt?: string | null
}

export interface CreateEmployeePortalTokenResult {
  tokenId: string
  secret: string
  supersededTokenId: string | null
}
