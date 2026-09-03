import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import type { Database } from '../types/database.types'

export interface SiteInfo {
  id: string
  tenant_id: string
  name: string
  address: string | null
  is_active: boolean
  metadata: Database['api']['Views']['sites']['Row']['metadata']
  // Structured address + canonical geo_coordinates (see src/lib/geo/geoCoordinates.ts).
  // Not yet in generated database.types.ts — see supabase/migrations/20261144000001
  // and 20261148000001_maps_expose_sites_contact_sites_columns.sql.
  street?: string | null
  street_number?: string | null
  city?: string | null
  province?: string | null
  postal_code?: string | null
  country_code?: string | null
  geo_coordinates?: Database['api']['Views']['sites']['Row']['metadata']
}

export type EntityStatusFilter = 'active' | 'inactive' | 'all'

interface UseSitesOptions {
  enabled?: boolean
}

function statusToIsActive(status: EntityStatusFilter): boolean | null {
  if (status === 'active') return true
  if (status === 'inactive') return false
  return null
}

/**
 * Retorna els sites del tenant seleccionat amb filtre d'estat.
 * Requereix userId per garantir que la query no es dispara sense JWT.
 */
export function useSites(
  tenantId: string | null,
  userId: string | undefined,
  status: EntityStatusFilter = 'active',
  options?: UseSitesOptions,
) {
  const isActiveFilter = statusToIsActive(status)
  const isEnabled = options?.enabled ?? true

  return useQuery<SiteInfo[]>({
    queryKey: ['sites', tenantId, status],
    enabled: !!tenantId && !!userId && isEnabled,
    queryFn: async () => {
      let query = supabase
        .from('sites')
        .select(
          'id, tenant_id, name, address, is_active, metadata, street, street_number, city, province, postal_code, country_code, geo_coordinates',
        )
        .eq('tenant_id', tenantId!)
        .order('name')

      if (isActiveFilter !== null) {
        query = query.eq('is_active', isActiveFilter)
      }

      const { data, error } = await query

      if (error) throw error
      return (data as unknown) as SiteInfo[]
    },
  })
}
