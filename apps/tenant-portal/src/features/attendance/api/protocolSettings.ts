import type { WorkProfile } from './recordPolicyTypes'
import { WORK_PROFILE_OPTIONS } from './recordPolicyTypes'

export interface ProtocolSettings {
  requiresSignature: boolean
  requiredBeforePunch: boolean
  /** Publica automàticament quan l'empleat obté portal o canvia de grup de conveni */
  autoOnboarding: boolean
  /** Tenant default template locale; null = platform default */
  defaultTemplateLocaleId: string | null
  /** Per-profile overrides (only set keys) */
  profileTemplateLocaleIds: Partial<Record<WorkProfile, string>>
}

export const PROTOCOL_SETTINGS_DEFAULTS: ProtocolSettings = {
  requiresSignature: false,
  requiredBeforePunch: false,
  autoOnboarding: false,
  defaultTemplateLocaleId: null,
  profileTemplateLocaleIds: {},
}

const KEYS = {
  requiresSignature: 'attendance_protocol_requires_signature',
  requiredBeforePunch: 'attendance_protocol_required_before_punch',
  autoOnboarding: 'attendance_protocol_auto_onboarding',
  defaultTemplateLocaleId: 'attendance_protocol_template_locale_id',
  profileTemplates: 'attendance_protocol_template_by_profile',
} as const

function boolSetting(raw: Record<string, unknown>, key: string, defaultValue: boolean): boolean {
  const v = raw[key]
  if (v === undefined || v === null) return defaultValue
  return v === true
}

function parseUuidOrNull(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null
  const s = String(value).trim()
  return s || null
}

function parseProfileTemplateMap(raw: unknown): Partial<Record<WorkProfile, string>> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return {}
  }

  const source = raw as Record<string, unknown>
  const result: Partial<Record<WorkProfile, string>> = {}

  for (const option of WORK_PROFILE_OPTIONS) {
    const id = parseUuidOrNull(source[option.value])
    if (id) {
      result[option.value] = id
    }
  }

  return result
}

export function parseProtocolSettings(
  raw: Record<string, unknown> | undefined | null,
): ProtocolSettings {
  const s = raw ?? {}
  return {
    requiresSignature: boolSetting(s, KEYS.requiresSignature, false),
    requiredBeforePunch: boolSetting(s, KEYS.requiredBeforePunch, false),
    autoOnboarding: boolSetting(s, KEYS.autoOnboarding, false),
    defaultTemplateLocaleId: parseUuidOrNull(s[KEYS.defaultTemplateLocaleId]),
    profileTemplateLocaleIds: parseProfileTemplateMap(s[KEYS.profileTemplates]),
  }
}

export function protocolSettingsPayload(settings: ProtocolSettings): Record<string, unknown> {
  const profilePayload: Record<string, string | null> = {}
  for (const option of WORK_PROFILE_OPTIONS) {
    const value = settings.profileTemplateLocaleIds[option.value]
    if (value) {
      profilePayload[option.value] = value
    }
  }

  return {
    [KEYS.requiresSignature]: settings.requiresSignature,
    [KEYS.requiredBeforePunch]: settings.requiredBeforePunch,
    [KEYS.autoOnboarding]: settings.autoOnboarding,
    [KEYS.defaultTemplateLocaleId]: settings.defaultTemplateLocaleId,
    [KEYS.profileTemplates]: profilePayload,
  }
}
