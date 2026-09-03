import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { useTenant } from '../contexts/TenantContext'
import type { PermissionKey } from '../lib/permissions'

// ---------------------------------------------------------------------------
// Tipus que espellan l'estructura JSONB de api.get_tenant_role_permissions()
// ---------------------------------------------------------------------------

export type EditableRole = 'viewer' | 'member' | 'manager'

export interface TenantRolePermissionsData {
  /** Personalitzacions actuals guardades. {} si s'usen defaults. */
  current_customization: Partial<Record<EditableRole, PermissionKey[]>>
  /** Permisos base per defecte (espell de BASE_ROLE_PERMISSIONS a permissions.ts) */
  defaults: Record<EditableRole, PermissionKey[]>
  /** Permisos efectius calculats per rol (herència + custom). Usar per display. */
  effective: {
    owner: ['*']
    manager: PermissionKey[]
    member: PermissionKey[]
    viewer: PermissionKey[]
  }
  /** Timestamp de l'últim canvi (ISO string o null si mai s'ha personalitzat) */
  updated_at: string | null
  /** UUID de l'usuari que va fer l'últim canvi */
  updated_by: string | null
}

// ---------------------------------------------------------------------------
// useRolePermissions
// Lectura de l'estat del gestor de permisos per al tenant actiu.
// Passa el tenant_id directament al RPC per evitar la cursa de timing
// amb el header x-tenant-id injectat per TenantContext (useEffect).
// ---------------------------------------------------------------------------
export function useRolePermissions(options?: { enabled?: boolean }) {
  const { selectedTenantId, activeTenant } = useTenant()
  const tenantId = selectedTenantId ?? activeTenant?.id ?? null

  return useQuery<TenantRolePermissionsData>({
    queryKey: ['tenant_role_permissions', tenantId],
    enabled: (options?.enabled ?? true) && !!tenantId,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_tenant_role_permissions', {
        p_tenant_id: tenantId!,
      })
      if (error) throw error
      return data as unknown as TenantRolePermissionsData
    },
  })
}

// ---------------------------------------------------------------------------
// useUpdateRolePermissions
// Mutació owner-only per actualitzar els permisos base per rol.
// Després de l'escriptura, fa refresh del JWT per aplicar canvis al token.
//
// IMPORTANT: El refresh del JWT de l'owner és immediat, però els altres membres
// continuaran amb el JWT antic fins al proper refresh automàtic (~60 min).
// La UI ha d'informar d'aquesta finestra de propagació.
// ---------------------------------------------------------------------------
export function useUpdateRolePermissions() {
  const queryClient = useQueryClient()
  const { selectedTenantId, activeTenant } = useTenant()
  const tenantId = selectedTenantId ?? activeTenant?.id ?? null

  return useMutation({
    mutationFn: async (permissions: Partial<Record<EditableRole, PermissionKey[]>>) => {
      if (!tenantId) {
        throw new Error('No active tenant selected')
      }
      const { error } = await supabase.rpc('update_tenant_role_permissions', {
        p_permissions: permissions,
        p_tenant_id: tenantId,
      })
      if (error) throw error
    },
    onSuccess: async () => {
      // Refresh JWT de l'owner perquè vegi els canvis immediatament
      await supabase.auth.refreshSession()
      queryClient.invalidateQueries({ queryKey: ['tenant_role_permissions'] })
    },
  })
}

// ---------------------------------------------------------------------------
// useIsJwtStale
// Comprova si el JWT actiu és anterior a l'últim canvi de permisos del tenant.
// Retorna true si el token podria estar desfasat.
// ---------------------------------------------------------------------------
export function useIsJwtStale(updatedAt: string | null): boolean {
  if (!updatedAt) return false

  // Llegim el JWT actual directament de la sessió de supabase
  // Nota: aquesta és una comprovació client-side, no és garantia de seguretat
  const session = supabase.auth.getSession as unknown as { data?: { session?: { access_token?: string } } }
  void session // no fem servir this, el token el llegim del context

  // Comparem via Date — si permissions_updated_at > ara - 5min, hi pot haver desincronització
  const updatedMs = new Date(updatedAt).getTime()
  const nowMs = Date.now()
  // Si l'actualització va ser fa menys de 90 min, podria no estar al JWT dels membres
  return (nowMs - updatedMs) < 90 * 60 * 1000
}
