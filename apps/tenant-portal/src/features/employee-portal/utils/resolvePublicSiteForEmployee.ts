import { supabase } from '@/lib/supabase'

export interface ResolvedPublicSiteForEmployee {
  public_site_id: string | null
  site_id: string | null
  site_name: string | null
  slug: string | null
  canonical_domain: string | null
  portal_base_url: string | null
  fallback_used: boolean
  draft_site_used?: boolean
  site_configured?: boolean
  tenant_slug: string
}

export async function resolvePublicSiteForEmployee(
  employeeId: string,
): Promise<ResolvedPublicSiteForEmployee> {
  const { data, error } = await supabase.rpc('resolve_public_site_for_employee', {
    p_employee_id: employeeId,
  })

  if (error) throw error
  if (!data || typeof data !== 'object') {
    throw new Error('missing_resolve_public_site_payload')
  }

  return data as ResolvedPublicSiteForEmployee
}
