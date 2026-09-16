import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'

export type SectorLabelKey = 'project' | 'contact' | string

/**
 * Resolves a sector_profiles.labels key for the active tenant.
 * Falls back to the provided default when the archetype has no override.
 */
export function useSectorLabel(key: SectorLabelKey, fallback: string): string {
  const { activeTenant } = useTenant()
  const labels = activeTenant?.sector_labels
  if (labels && typeof labels === 'object' && !Array.isArray(labels)) {
    const value = (labels as Record<string, unknown>)[key]
    if (typeof value === 'string' && value.trim()) return value
  }
  return fallback
}

export function useIsFieldService(): boolean {
  const { activeTenant } = useTenant()
  return activeTenant?.archetype === 'field_service'
}

/** List/nav label for `/contacts`: plural in field service ("Clients"), singular sector override otherwise. */
export function useSectorContactListLabel(): string {
  const { t } = useTranslation('common')
  const { t: tField } = useTranslation('field-service')
  const isFieldService = useIsFieldService()
  const pluralOverride = useSectorLabel('contacts', '')
  const singular = useSectorLabel('contact', t('nav.contacts', 'Contactes'))
  if (pluralOverride) return pluralOverride
  if (isFieldService) return tField('more.clients', t('nav.clients', 'Clients'))
  return singular
}
