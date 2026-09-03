// =============================================================================
// useCalendarEvents.ts — Hook de càrrega d'events del calendari
// =============================================================================
// Càrrega dels events del mes visible de api.calendar_events via supabase-js.
// Filtra per rang de dates (start_at, end_at) i pel tenant actiu.
// =============================================================================

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useTenant } from '../../contexts/TenantContext'
import { CalendarRegistry } from './CalendarRegistry'
import type { AddonStatus, CalendarEventRow, CalendarResolvedEvent } from './calendar.types'

interface UseCalendarEventsOptions {
  /** Primer dia del rang visible (inclòs) */
  rangeStart: Date
  /** Últim dia del rang visible (inclòs) */
  rangeEnd: Date
  /** Si s'especifica, filtra per un site concret. null = tots els sites del tenant */
  siteId?: string | null
}

export function useCalendarEvents({
  rangeStart,
  rangeEnd,
  siteId,
}: UseCalendarEventsOptions) {
  const { selectedTenantId, activeTenant } = useTenant()
  const projectSectorLabel = activeTenant?.sector_labels?.project
  const normalizedSiteId = typeof siteId === 'string' && siteId.trim().length > 0 ? siteId : null
  const normalizedRangeStart = rangeStart <= rangeEnd ? rangeStart : rangeEnd
  const normalizedRangeEnd = rangeStart <= rangeEnd ? rangeEnd : rangeStart

  return useQuery<CalendarResolvedEvent[]>({
    queryKey: [
      'calendar_events',
      selectedTenantId,
      normalizedSiteId,
      normalizedRangeStart.toISOString(),
      normalizedRangeEnd.toISOString(),
      projectSectorLabel ?? '',
    ],
    enabled: !!selectedTenantId,
    queryFn: async () => {
      if (!selectedTenantId) return []

      let query = supabase
        .from('calendar_events')
        .select('*')
        .eq('tenant_id', selectedTenantId)
        .lte('start_at', normalizedRangeEnd.toISOString())
        .or(`end_at.gte.${normalizedRangeStart.toISOString()},end_at.is.null`)
        .order('start_at', { ascending: true })

      if (normalizedSiteId) {
        // Filtra per site concret (inclou events globals del tenant: site_id IS NULL)
        query = query.or(`site_id.eq.${normalizedSiteId},site_id.is.null`)
      }

      const { data, error } = await query

      if (error) throw error

      const rows = (data ?? []) as CalendarEventRow[]

      return rows.map((event) => {
        const def = CalendarRegistry.get(event.entity_type ?? '')
        const addonStatus = event.addon_status as AddonStatus
        const addonUnavailable = addonStatus === 'canceled' || addonStatus === 'expired'
        const label =
          event.entity_type === 'project' && projectSectorLabel
            ? projectSectorLabel
            : (def?.label ?? (event.entity_type ?? 'event'))

        return {
          ...event,
          moduleDefinition: def,
          resolvedLabel: label,
          resolvedColor: addonUnavailable
            ? '#9ca3af'
            : (event.color ?? def?.defaultColor ?? '#6366f1'),
          resolvedIcon: def?.icon,
          addonUnavailable,
          viewPermission: def?.viewPermission ?? 'calendar.view',
          editPermission: def?.editPermission ?? 'calendar.edit',
        }
      })
    },
    staleTime: 1000 * 60 * 5, // 5 minuts — el calendari no necessita temps real
  })
}
