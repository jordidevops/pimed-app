import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import { signingKeys } from './signingKeys'

export type TenantRoleDefault = Database['api']['Views']['tenant_role_defaults']['Row']

// Mapa indexat per `role_key::entity_type` per a accés O(1) a l'orquestrador.
// Prioritat: site-specific > tenant-global.
export type TenantRoleDefaultsMap = Record<string, TenantRoleDefault>

/**
 * Builds a priority map: site-specific defaults override tenant-global defaults.
 * Key format: `${role_key}::${entity_type}`
 */
export function buildPriorityDefaultsMap(
  defaults: TenantRoleDefault[],
  siteId: string | null | undefined,
): TenantRoleDefaultsMap {
  const map: TenantRoleDefaultsMap = {}
  // Pass 1: tenant-global (site_id IS NULL)
  for (const d of defaults) {
    if (!d.role_key || !d.entity_type) continue
    if (!d.site_id) {
      map[`${d.role_key}::${d.entity_type}`] = d
    }
  }
  // Pass 2: site-specific (overwrites global for same key)
  if (siteId) {
    for (const d of defaults) {
      if (!d.role_key || !d.entity_type) continue
      if (d.site_id === siteId) {
        map[`${d.role_key}::${d.entity_type}`] = d
      }
    }
  }
  return map
}

export function useTenantRoleDefaults(tenantId: string | undefined) {
  return useQuery<TenantRoleDefault[]>({
    queryKey: signingKeys.roleDefaults(tenantId ?? ''),
    queryFn: async () => {
      if (!tenantId) return []
      const { data, error } = await supabase
        .from('tenant_role_defaults')
        .select('*')
        .eq('tenant_id', tenantId)
      if (error) throw error
      return (data ?? []) as TenantRoleDefault[]
    },
    enabled: !!tenantId,
    staleTime: 5 * 60 * 1000, // 5 min — canvien poc sovint
  })
}

// ─── Mutations ────────────────────────────────────────────────────────────────

interface UpsertRoleDefaultParams {
  tenantId:     string
  roleKey:      string
  entityType:   string
  entityId?:    string | null
  entityLabel?: string | null
  entityEmail?: string | null
  siteId?:      string | null
}

export function useUpsertRoleDefault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (p: UpsertRoleDefaultParams) => {
      const { data, error } = await supabase.rpc('upsert_tenant_role_default', {
        p_tenant_id:    p.tenantId,
        p_role_key:     p.roleKey,
        p_entity_type:  p.entityType,
        p_entity_id:    p.entityId    ?? undefined,
        p_entity_label: p.entityLabel ?? undefined,
        p_entity_email: p.entityEmail ?? undefined,
        p_site_id:      p.siteId      ?? undefined,
      })
      if (error) throw error
      return data
    },
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: signingKeys.roleDefaults(variables.tenantId) })
    },
  })
}

interface DeleteRoleDefaultParams {
  id:       string
  tenantId: string
}

export function useDeleteRoleDefault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (p: DeleteRoleDefaultParams) => {
      const { error } = await supabase.rpc('delete_tenant_role_default', {
        p_id:        p.id,
        p_tenant_id: p.tenantId,
      })
      if (error) throw error
    },
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: signingKeys.roleDefaults(variables.tenantId) })
    },
  })
}

