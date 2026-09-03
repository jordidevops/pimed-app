export type AttendanceWorkProfileFormValue =
  | 'inherit'
  | 'fixed_site'
  | 'mobile_peripatetic'
  | 'hybrid'
  | 'delivery'

export function toAttendanceWorkProfileFormValue(
  value: string | null | undefined,
): AttendanceWorkProfileFormValue {
  if (
    value === 'fixed_site'
    || value === 'mobile_peripatetic'
    || value === 'hybrid'
    || value === 'delivery'
  ) {
    return value
  }
  return 'inherit'
}

export function fromAttendanceWorkProfileFormValue(
  value: AttendanceWorkProfileFormValue,
): string | null {
  if (value === 'inherit') return null
  return value
}

export const WORK_PROFILE_FORM_OPTIONS: {
  value: AttendanceWorkProfileFormValue
  label: string
}[] = [
  { value: 'inherit', label: 'Hereta del grup / conveni' },
  { value: 'fixed_site', label: 'Centre fix (oficina/fàbrica)' },
  { value: 'mobile_peripatetic', label: 'Itinerant (camp)' },
  { value: 'hybrid', label: 'Híbrid' },
  { value: 'delivery', label: 'Repartiment / logística' },
]
