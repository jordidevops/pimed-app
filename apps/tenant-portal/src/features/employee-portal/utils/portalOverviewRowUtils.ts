import type { PortalAccessOverviewRow } from '../api/employeePortalOverviewTypes'
import type { EmployeePortalToken } from '../api/employeePortalTypes'

export function overviewRowToRevokeToken(
  row: PortalAccessOverviewRow,
): EmployeePortalToken | null {
  const id = row.personal.token_id
  if (!id || !row.personal.has_active) return null

  return {
    id,
    tenant_id: '',
    employee_id: row.employee_id,
    pin_required:
      row.personal.pin_required ??
      Boolean(row.personal.pin_must_set || row.personal.pin_configured),
    pin_attempts: 0,
    pin_locked_until: null,
    session_version: 0,
    compromised: false,
    expires_at: null,
    is_active: true,
    label: row.personal.label,
    first_accessed_at: row.personal.first_accessed_at,
    last_accessed_at: row.personal.last_accessed_at,
    created_by_user_id: null,
    created_at: row.personal.created_at ?? '',
    revoked_at: null,
    revoke_reason: null,
  }
}
