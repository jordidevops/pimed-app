export type OvertimePolicy = 'approval_required' | 'auto_if_allowed'

export const OVERTIME_POLICY_OPTIONS: OvertimePolicy[] = [
  'approval_required',
  'auto_if_allowed',
]

export const DEFAULT_OVERTIME_POLICY: OvertimePolicy = 'approval_required'

const KEY = 'attendance_overtime_policy'

export function parseOvertimePolicy(
  effective: Record<string, unknown> | undefined | null,
): OvertimePolicy {
  const raw = effective?.[KEY]
  if (raw === 'auto_if_allowed') return 'auto_if_allowed'
  return 'approval_required'
}

export function overtimePolicyPayload(policy: OvertimePolicy): Record<string, string> {
  return { [KEY]: policy }
}

export function requiresOvertimeApproval(policy: OvertimePolicy): boolean {
  return policy === 'approval_required'
}
