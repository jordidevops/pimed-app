import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type Location = Database['api']['Views']['locations']['Row']
export type LocationInsert = Database['api']['Views']['locations']['Insert']
export type LocationUpdate = Database['api']['Views']['locations']['Update']

export function normalizeLocError(error: unknown): 'unauthorized' | 'not_found' | 'generic' {
  if (typeof error === 'object' && error !== null) {
    const e = error as { code?: string; status?: number }
    if (e.code === '42501' || e.status === 403) return 'unauthorized'
    if (e.code === 'PGRST116' || e.status === 404) return 'not_found'
  }
  return 'generic'
}

export function getAncestors(locations: Location[], locationId: string | null): Location[] {
  if (!locationId) return []
  const loc = locations.find((l) => l.id === locationId)
  if (!loc) return []
  return [...getAncestors(locations, loc.parent_id ?? null), loc]
}

export function getDescendantIds(locations: Location[], locationId: string): string[] {
  const children = locations.filter((l) => l.parent_id === locationId)
  return children.flatMap((c) => [c.id!, ...getDescendantIds(locations, c.id!)])
}

export async function getLocations(siteId?: string | null): Promise<Location[]> {
  let query = supabase.from('locations').select('*').order('name', { ascending: true })
  if (siteId) query = query.eq('site_id', siteId)
  const { data, error } = await query
  if (error) throw error
  return data ?? []
}

export interface CreateLocationParams {
  tenant_id: string
  name: string
  type: string
  status: string
  site_id: string
  parent_id?: string | null
  geo_coordinates?: LocationInsert['geo_coordinates']
}

export async function createLocation(params: CreateLocationParams): Promise<Location> {
  const { data, error } = await supabase.from('locations').insert(params).select().single()
  if (error) throw error
  return data
}

export interface UpdateLocationParams {
  name?: string
  type?: string
  status?: string
  parent_id?: string | null
  metadata?: LocationUpdate['metadata']
  geo_coordinates?: LocationUpdate['geo_coordinates']
}

export async function updateLocation(id: string, params: UpdateLocationParams): Promise<Location> {
  const { data, error } = await supabase
    .from('locations')
    .update(params)
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data
}
