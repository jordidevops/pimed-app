export interface EmployeePortalSessionClaims {
  sub: "employee_portal";
  employee_id: string;
  tenant_id: string;
  token_id: string;
  session_version: number;
  iat: number;
  exp: number;
}

export interface EmployeePortalEmployee {
  id: string;
  tenant_id: string;
  full_name: string;
  pin_required: boolean;
  work_profile?: string;
  legacy_in_out_only?: boolean;
}

export interface PortalPublicPolicy {
  default_pin_required: boolean;
}

export interface SessionSuccessResponse {
  session_token: string;
  expires_in: number;
  employee: EmployeePortalEmployee;
  portal_policy?: PortalPublicPolicy;
}

export interface TokenRecord {
  token_id: string;
  tenant_id: string;
  employee_id: string;
  full_name: string;
  secret_hash: Uint8Array;
  session_version: number;
  is_active: boolean;
  revoked_at: string | null;
  pin_required: boolean;
  pin_must_set: boolean;
  pin_hash: string | null;
  pin_attempts?: number;
  pin_locked_until?: string | null;
  compromised: boolean;
  expires_at?: string | null;
  identity_verified_at?: string | null;
  identity_required?: boolean;
  has_document_id?: boolean;
  identity_attempts?: number;
  identity_locked_until?: string | null;
}
