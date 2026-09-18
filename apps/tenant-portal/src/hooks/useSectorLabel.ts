import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useEffectiveSettings } from '@/hooks/useSettings'
import { resolveTerm } from '@/features/terminology/resolveTerm'

export type SectorLabelKey = 'project' | 'project_plural' | 'contact' | 'contacts' | 'price_sheet' | string

/**
 * Resolves tenant overlay → sector_profiles.labels → fallback.
 */
export function useSectorLabel(key: SectorLabelKey, fallback: string): string {
  const { activeTenant } = useTenant()
  const { data: settings } = useEffectiveSettings(
    { tenantId: activeTenant?.id ?? null },
    { enabled: !!activeTenant?.id },
  )
  return resolveTerm(key, {
    tenant: settings?.terminology,
    sector: activeTenant?.sector_labels,
    fallback,
  })
}

export function usePriceSheetTitle(): string {
  const { t } = useTranslation('projects')
  return useSectorLabel('price_sheet', t('projects.lines.title', 'Full de preus'))
}

export function useIsFieldService(): boolean {
  const { activeTenant } = useTenant()
  return activeTenant?.archetype === 'field_service'
}

/** List/nav label for `/contacts`: plural overlay/seed, then FSM i18n, then singular. */
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
