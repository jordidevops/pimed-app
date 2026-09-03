import { supabase } from '@/lib/supabase'

export type CompensationMovementType =
  | 'accrued'
  | 'compensated_time_off'
  | 'paid_payroll'
  | 'manual_adjustment'
  | 'expired'

export type CompensationSourceType = 'overtime' | 'holiday_worked' | 'manual'

/** UI form kinds mapped to RPC parameters in recordCompensationMovement. */
export type CompensationMovementKind =
  | 'compensated_time_off'
  | 'paid_payroll'
  | 'holiday_worked'
  | 'manual_credit'
  | 'manual_debit'

export interface CompensationLedgerMovement {
  id: string
  created_at: string
  source_work_date: string | null
  movement_type: CompensationMovementType
  source_type: CompensationSourceType
  minutes: number
  is_credit: boolean
  signed_minutes: number
  notes: string | null
  created_by_name: string | null
}

export interface CompensationLedgerResult {
  employee_id: string
  balance_minutes: number
  movements: CompensationLedgerMovement[]
}

export interface RecordCompensationMovementInput {
  employeeId: string
  kind: CompensationMovementKind
  minutes: number
  sourceWorkDate?: string | null
  notes?: string | null
}

function kindToRpcParams(kind: CompensationMovementKind): {
  movement_type: CompensationMovementType
  source_type: CompensationSourceType
  is_credit: boolean
} {
  switch (kind) {
    case 'compensated_time_off':
      return { movement_type: 'compensated_time_off', source_type: 'overtime', is_credit: false }
    case 'paid_payroll':
      return { movement_type: 'paid_payroll', source_type: 'overtime', is_credit: false }
    case 'holiday_worked':
      return { movement_type: 'accrued', source_type: 'holiday_worked', is_credit: true }
    case 'manual_credit':
      return { movement_type: 'manual_adjustment', source_type: 'manual', is_credit: true }
    case 'manual_debit':
      return { movement_type: 'manual_adjustment', source_type: 'manual', is_credit: false }
  }
}

export async function fetchCompensationLedger(
  employeeId: string,
  limit = 50,
): Promise<CompensationLedgerResult> {
  const { data, error } = await supabase.rpc('list_compensation_ledger' as never, {
    p_employee_id: employeeId,
    p_limit: limit,
    p_offset: 0,
  } as never)

  if (error) throw error
  return data as CompensationLedgerResult
}

export async function recordCompensationMovement(
  input: RecordCompensationMovementInput,
): Promise<string> {
  const { movement_type, source_type, is_credit } = kindToRpcParams(input.kind)

  if (input.kind === 'holiday_worked' && !input.sourceWorkDate) {
    throw new Error('source_work_date_required')
  }

  const { data, error } = await supabase.rpc('record_compensation_movement' as never, {
    p_employee_id: input.employeeId,
    p_movement_type: movement_type,
    p_minutes: input.minutes,
    p_source_type: source_type,
    p_is_credit: is_credit,
    p_source_work_date: input.sourceWorkDate ?? null,
    p_notes: input.notes?.trim() || null,
  } as never)

  if (error) throw error
  return String(data)
}

export function movementLabelKey(
  movement: Pick<CompensationLedgerMovement, 'movement_type' | 'source_type'>,
): string {
  if (movement.movement_type === 'accrued' && movement.source_type === 'holiday_worked') {
    return 'compensation_ledger.movement.holiday_worked'
  }
  if (movement.movement_type === 'accrued' && movement.source_type === 'overtime') {
    return 'compensation_ledger.movement.accrued_overtime'
  }
  return `compensation_ledger.movement.${movement.movement_type}`
}
