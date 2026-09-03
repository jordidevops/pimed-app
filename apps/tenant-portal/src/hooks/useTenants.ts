import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

export interface TenantInfo {
  id: string
  name: string
  slug: string
  plan_name: string | null
  plan_display_name: string | null
  max_members: number
  max_sites: number
  role: string
  /** Logo URL del tenant (opcional, si la vista el retorna) */
  logo_url?: string | null
  /** NULL = onboarding pendent (cal mostrar el wizard) */
  sector_profile_id: string | null
  archetype: string | null
  sector_icon: string | null
  sector_display_name: string | null
  sector_vertical: string | null
  /** Labels from sector_profiles (e.g. project → Ordre de servei) */
  sector_labels: Record<string, string> | null
}

/**
 * Retorna tots els tenants als quals pertany l'usuari autenticat, amb el seu rol.
 * Combina api.my_tenant (noms/pla) i api.tenant_members (rol).
 * El client Supabase gestiona el JWT automàticament.
 *
 * Important: la llista d'organitzacions NO s'ha de filtrar per x-tenant-id
 * (si no, el selector desapareix i l'usuari queda atrapat en un sol tenant).
 * Fem-ho amb `.setHeader` per-request — MAI tocant el header global del client,
 * perquè això provoca races amb contactes/features al refetchOnWindowFocus.
 */
export function useTenants(userId: string | undefined) {
  return useQuery<TenantInfo[]>({
    queryKey: ['tenants', userId],
    enabled: !!userId,
    queryFn: async () => {
      const [tenantsRes, membershipsRes] = await Promise.all([
        supabase
          .from('my_tenant')
          .select('id, name, slug, plan_name, plan_display_name, max_members, max_sites, sector_profile_id, archetype, sector_icon, sector_display_name, sector_vertical, sector_labels')
          // Empty → active_tenant_id() = NULL for this request only (see data.active_tenant_id).
          .setHeader('x-tenant-id', ''),
        supabase
          .from('tenant_members')
          .select('tenant_id, role, site_id')
          .eq('user_id', userId!)
          .eq('is_active', true)
          .setHeader('x-tenant-id', ''),
      ])

      if (tenantsRes.error) throw tenantsRes.error
      if (membershipsRes.error) throw membershipsRes.error

      // Rol global: només la fila amb site_id = NULL.
      // Si no existeix rol global per al tenant, el frontend el tracta com a viewer.
      const roleMap = new Map(
        membershipsRes.data
          .filter((m) => m.site_id == null)
          .map((m) => [m.tenant_id as string, m.role as string]),
      )

      return tenantsRes.data.map((t) => {
        const rawLabels = t.sector_labels
        let sector_labels: Record<string, string> | null = null
        if (rawLabels && typeof rawLabels === 'object' && !Array.isArray(rawLabels)) {
          const entries = Object.entries(rawLabels as Record<string, unknown>).filter(
            (e): e is [string, string] => typeof e[1] === 'string',
          )
          if (entries.length > 0) sector_labels = Object.fromEntries(entries)
        }
        return {
          id:                  t.id as string,
          name:                t.name as string,
          slug:                t.slug as string,
          plan_name:           t.plan_name as string | null,
          plan_display_name:   t.plan_display_name as string | null,
          max_members:         (t.max_members as number) ?? 1,
          max_sites:           (t.max_sites as number) ?? 1,
          role:                roleMap.get(t.id as string) ?? 'viewer',
          sector_profile_id:   (t.sector_profile_id as string | null) ?? null,
          archetype:           (t.archetype as string | null) ?? null,
          sector_icon:         (t.sector_icon as string | null) ?? null,
          sector_display_name: (t.sector_display_name as string | null) ?? null,
          sector_vertical:     (t.sector_vertical as string | null) ?? null,
          sector_labels,
        }
      })
    },
  })
}
