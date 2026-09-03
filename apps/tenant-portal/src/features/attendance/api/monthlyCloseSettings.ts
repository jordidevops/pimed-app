import type { MonthPeriodStatus } from './periodConfirmService'

export type EmployeeConfirmCycle = 'calendar_month' | 'iso_week'

export const EMPLOYEE_CONFIRM_CYCLE_OPTIONS: EmployeeConfirmCycle[] = [
  'calendar_month',
  'iso_week',
]

export interface MonthlyCloseSettings {
  employeeConfirmRequired: boolean
  signatureIsEmployeeApproval: boolean
  managerCanCloseWithoutEmployee: boolean
  requireDigitalSignature: boolean
  bulkApproveDaysOnClose: boolean
  employeeConfirmCycle: EmployeeConfirmCycle
}

export const MONTHLY_CLOSE_SETTINGS_DEFAULTS: MonthlyCloseSettings = {
  employeeConfirmRequired: true,
  signatureIsEmployeeApproval: false,
  managerCanCloseWithoutEmployee: true,
  requireDigitalSignature: false,
  bulkApproveDaysOnClose: true,
  employeeConfirmCycle: 'calendar_month',
}

const KEYS = {
  employeeConfirmRequired: 'attendance_monthly_employee_confirm_required',
  signatureIsEmployeeApproval: 'attendance_monthly_signature_is_employee_approval',
  managerCanCloseWithoutEmployee: 'attendance_monthly_manager_can_close_without_employee',
  requireDigitalSignature: 'attendance_monthly_require_digital_signature',
  bulkApproveDaysOnClose: 'attendance_monthly_bulk_approve_days_on_close',
  employeeConfirmCycle: 'attendance_employee_confirm_cycle',
} as const

function boolSetting(raw: Record<string, unknown>, key: string, defaultValue: boolean): boolean {
  const v = raw[key]
  if (v === undefined || v === null) return defaultValue
  return v === true
}

function cycleSetting(
  raw: Record<string, unknown>,
  defaultValue: EmployeeConfirmCycle,
): EmployeeConfirmCycle {
  const v = raw[KEYS.employeeConfirmCycle]
  if (v === 'iso_week') return 'iso_week'
  return defaultValue
}

export function parseMonthlyCloseSettings(
  raw: Record<string, unknown> | undefined | null,
): MonthlyCloseSettings {
  const s = raw ?? {}
  return {
    employeeConfirmRequired: boolSetting(s, KEYS.employeeConfirmRequired, true),
    signatureIsEmployeeApproval: boolSetting(s, KEYS.signatureIsEmployeeApproval, false),
    managerCanCloseWithoutEmployee: boolSetting(s, KEYS.managerCanCloseWithoutEmployee, true),
    requireDigitalSignature: boolSetting(s, KEYS.requireDigitalSignature, false),
    bulkApproveDaysOnClose: boolSetting(s, KEYS.bulkApproveDaysOnClose, true),
    employeeConfirmCycle: cycleSetting(s, 'calendar_month'),
  }
}

export function monthlyCloseSettingsPayload(
  settings: MonthlyCloseSettings,
): Record<string, boolean | string> {
  return {
    [KEYS.employeeConfirmRequired]: settings.employeeConfirmRequired,
    [KEYS.signatureIsEmployeeApproval]: settings.signatureIsEmployeeApproval,
    [KEYS.managerCanCloseWithoutEmployee]: settings.managerCanCloseWithoutEmployee,
    [KEYS.requireDigitalSignature]: settings.requireDigitalSignature,
    [KEYS.bulkApproveDaysOnClose]: settings.bulkApproveDaysOnClose,
    [KEYS.employeeConfirmCycle]: settings.employeeConfirmCycle,
  }
}

export const EMPLOYEE_CONFIRM_CYCLE_LABEL_DEFAULTS: Record<EmployeeConfirmCycle, string> = {
  calendar_month: 'Mes natural',
  iso_week: 'Setmana ISO (dilluns–diumenge)',
}

export function employeeConfirmCycleLabelKey(cycle: EmployeeConfirmCycle): string {
  return `config.monthly_close.employee_confirm_cycle_${cycle}`
}

export function isMonthlyCloseBlockedByEmployeeConfirm(
  monthStatus: string,
  settings: MonthlyCloseSettings,
  periodStatus?: MonthPeriodStatus | null,
  periodStatusLoading?: boolean,
): boolean {
  if (settings.signatureIsEmployeeApproval) {
    return false
  }
  if (!settings.employeeConfirmRequired || settings.managerCanCloseWithoutEmployee) {
    return false
  }
  if (monthStatus !== 'draft') {
    return false
  }
  if (periodStatusLoading || !periodStatus) {
    return false
  }
  return !periodStatus.month_fully_confirmed
}

export function needsMonthlyCloseEmployeeAck(
  monthStatus: string,
  settings: MonthlyCloseSettings,
): boolean {
  return (
    monthStatus === 'draft' &&
    settings.employeeConfirmRequired &&
    settings.managerCanCloseWithoutEmployee
  )
}
