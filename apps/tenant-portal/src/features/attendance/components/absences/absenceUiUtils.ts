import type { AbsenceTypeConfig } from '../../api/shiftsService'

export const ABSENCE_STATUS_COLORS: Record<string, string> = {
  requested: 'bg-yellow-100 text-yellow-800 border-yellow-200',
  approved: 'bg-green-100 text-green-800 border-green-200',
  rejected: 'bg-red-100 text-red-800 border-red-200',
  cancelled: 'bg-gray-100 text-gray-600 border-gray-200',
  revoked: 'bg-amber-100 text-amber-800 border-amber-200',
  active: 'bg-blue-100 text-blue-800 border-blue-200',
  closed: 'bg-slate-100 text-slate-700 border-slate-200',
}

export function absenceTypeLabel(
  cfg: AbsenceTypeConfig | undefined,
  fallback: string,
  lang: string,
): string {
  if (!cfg) return fallback
  return cfg.name_i18n?.[lang] ?? cfg.name_i18n?.es ?? fallback
}

export function resolveAbsenceTypeLabel(
  absenceType: string | null | undefined,
  typeConfigMap: Record<string, AbsenceTypeConfig>,
  lang: string,
): string | null {
  if (!absenceType) return null
  return absenceTypeLabel(typeConfigMap[absenceType], absenceType, lang)
}

export function todayIsoDate(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
