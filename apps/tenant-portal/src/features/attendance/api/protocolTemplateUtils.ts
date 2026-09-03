import type { WorkProfile } from './recordPolicyTypes'
import { WORK_PROFILE_OPTIONS } from './recordPolicyTypes'
import type { ProtocolSettings } from './protocolSettings'

export const ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID =
  '71000000-0000-0000-0000-000000000030'

/** @deprecated Use ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID */
export const ATTENDANCE_PROTOCOL_TEMPLATE_LOCALE_ID =
  ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID

export type ProtocolProfileTemplateMap = Partial<Record<WorkProfile, string>>

export function resolveProtocolTemplateLocaleId(
  settings: Pick<ProtocolSettings, 'defaultTemplateLocaleId' | 'profileTemplateLocaleIds'>,
  workProfile: string,
): string {
  const profileKey = workProfile as WorkProfile
  const profileOverride = settings.profileTemplateLocaleIds[profileKey]?.trim()
  if (profileOverride) return profileOverride

  const tenantDefault = settings.defaultTemplateLocaleId?.trim()
  if (tenantDefault) return tenantDefault

  return ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID
}

export const PROTOCOL_WORK_PROFILES = WORK_PROFILE_OPTIONS.map((o) => o.value)
