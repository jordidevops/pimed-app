import type { FieldErrors } from 'react-hook-form'
import type { TFunction } from 'i18next'
import type { EmployeeFormInput } from '../schemas/employeeSchema'

const FIELD_ERROR_KEYS: Partial<Record<keyof EmployeeFormInput, string>> = {
  full_name: 'employees.validation.full_name_required',
  email: 'employees.validation.email_invalid',
  weekly_hours: 'employees.validation.weekly_hours_min',
  department_id: 'employees.validation.department_invalid',
  site_id: 'employees.validation.site_invalid',
}

export function employeeFieldErrorMessage(
  t: TFunction,
  field: keyof EmployeeFormInput,
  errors: FieldErrors<EmployeeFormInput>,
): string | null {
  const issue = errors[field]
  if (!issue?.message) return null
  const key = FIELD_ERROR_KEYS[field]
  if (key) return t(key, String(issue.message))
  return String(issue.message)
}

export function employeeValidationToastDescription(
  t: TFunction,
  errors: FieldErrors<EmployeeFormInput>,
): string {
  const fields = (Object.keys(errors) as Array<keyof EmployeeFormInput>).filter(
    (f) => errors[f],
  )
  if (fields.length === 0) {
    return t('employees.errors.validation', 'Revisa els camps marcats abans de desar.')
  }
  const labels = fields
    .map((f) => employeeFieldErrorMessage(t, f, errors))
    .filter(Boolean)
    .slice(0, 3)
  return labels.join(' · ')
}
