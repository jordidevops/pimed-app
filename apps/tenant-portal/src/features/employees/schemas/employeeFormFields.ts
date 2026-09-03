import { z } from 'zod'
import type { SiteInfo } from '@/hooks/useSites'

/** Accepta qualsevol UUID canònic (inclou IDs de seed com 30000000-0000-0000-0000-...). */
const UUID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

export function isUuid(value: string | null | undefined): value is string {
  return !!value && UUID_RE.test(value)
}

/** Normalitza valors de <select> abans de validar (evita "null", espais, etc.). */
export function sanitizeUuidField(value: string | null | undefined): string {
  if (value == null) return ''
  const trimmed = String(value).trim()
  if (!trimmed || trimmed.toLowerCase() === 'null' || trimmed.toLowerCase() === 'undefined') {
    return ''
  }
  return isUuid(trimmed) ? trimmed : ''
}

/** Cada camp necessita la seva pròpia instància Zod (no reutilitzar l'objecte). */
export function optionalUuidField() {
  return z
    .union([z.string(), z.literal(''), z.null(), z.undefined()])
    .transform((v) => sanitizeUuidField(typeof v === 'string' ? v : v == null ? '' : String(v)) || null)
    .refine((v) => v === null || isUuid(v), 'validation.uuid_invalid')
}

export function optionalWeeklyHoursField() {
  return z
    .union([z.number(), z.string(), z.null(), z.undefined()])
    .transform((v) => {
      if (v === '' || v === null || v === undefined) return null
      const n = typeof v === 'number' ? v : Number(v)
      return Number.isNaN(n) ? null : n
    })
    .refine((v) => v === null || v >= 0, 'validation.weekly_hours_min')
}

export type { AttendanceGeoEnabledFormValue } from '@/features/attendance/utils/attendanceGeoFormUtils'
export {
  fromAttendanceGeoEnabledFormValue,
  toAttendanceGeoEnabledFormValue,
} from '@/features/attendance/utils/attendanceGeoFormUtils'
export type { AttendanceWorkProfileFormValue } from '@/features/attendance/utils/attendanceWorkProfileFormUtils'
export {
  fromAttendanceWorkProfileFormValue,
  toAttendanceWorkProfileFormValue,
} from '@/features/attendance/utils/attendanceWorkProfileFormUtils'

export function optionalEmailField() {
  return z
    .union([z.literal(''), z.string().email('validation.email_invalid')])
    .transform((v) => (v === '' ? null : v))
}

/** Inclou el local assignat encara que estigui inactiu o fora del filtre actiu. */
export function buildEmployeeSiteOptions(
  sites: SiteInfo[],
  assignedSiteId: string | null | undefined,
  inactiveLabel = 'Local assignat (inactiu)',
): SiteInfo[] {
  if (!assignedSiteId || !isUuid(assignedSiteId)) return sites
  if (sites.some((s) => s.id === assignedSiteId)) return sites
  return [
    ...sites,
    {
      id: assignedSiteId,
      tenant_id: sites[0]?.tenant_id ?? '',
      name: inactiveLabel,
      address: null,
      is_active: false,
      metadata: null,
    },
  ]
}

export function defaultEmployeeSiteId(
  currentSiteId: string | null | undefined,
  sites: SiteInfo[],
  selectedSiteId: string | null,
): string {
  const sanitized = sanitizeUuidField(currentSiteId ?? '')
  if (sanitized) return sanitized
  if (selectedSiteId && isUuid(selectedSiteId) && sites.some((s) => s.id === selectedSiteId)) {
    return selectedSiteId
  }
  if (sites.length === 1) return sites[0].id
  return ''
}
