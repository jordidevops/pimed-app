import type { TFunction } from 'i18next'
import {
  RESOLVED_FROM_LABELS,
  WORK_PROFILE_OPTIONS,
  type WorkProfile,
} from '../api/recordPolicyTypes'

const PROFILE_KEY_BY_VALUE = Object.fromEntries(
  WORK_PROFILE_OPTIONS.map((o) => [o.value, o.labelKey]),
) as Record<WorkProfile, string>

export function formatWorkProfileLabel(
  t: TFunction<'attendance'>,
  profile: string | null | undefined,
  inheritLabel?: string,
): string {
  if (!profile || profile === 'inherit') {
    return inheritLabel ?? t('record_policy.profile_inherit', 'Hereta del grup / conveni')
  }
  const key = PROFILE_KEY_BY_VALUE[profile as WorkProfile]
  if (key) {
    return t(key, profile)
  }
  return profile
}

export function formatResolvedFromLabel(
  t: TFunction<'attendance'>,
  resolvedFrom: string,
): string {
  const fallback = RESOLVED_FROM_LABELS[resolvedFrom] ?? resolvedFrom
  return t(`record_policy.resolved_from.${resolvedFrom}`, fallback)
}
