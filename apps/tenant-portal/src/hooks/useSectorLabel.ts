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
