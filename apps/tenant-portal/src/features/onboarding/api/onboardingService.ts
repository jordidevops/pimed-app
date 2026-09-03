import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type SectorProfile = Database['api']['Views']['sector_profiles']['Row']

// --- Read -------------------------------------------------------------------

export async function getSectorProfiles(): Promise<SectorProfile[]> {
  const { data, error } = await supabase
    .from('sector_profiles')
    .select('*')
    .order('sort_order', { ascending: true })

  if (error) throw error
  return data ?? []
}

// --- Apply ------------------------------------------------------------------

export async function applySectorRecipe(
  sectorProfileId: string,
  companyName?: string,
  tenantId?: string,
): Promise<void> {
  const { error } = await supabase.rpc('apply_sector_recipe', {
    p_sector_profile_id: sectorProfileId,
    p_company_name:      companyName ?? undefined,
    p_tenant_id:         tenantId    ?? undefined,
  })
  if (error) throw error
}
