import { useAuth } from '../contexts/AuthContext'
import { useTenant } from '../contexts/TenantContext'
import { ROLE_LEVELS } from '../lib/permissions'

export type { Role } from '../lib/permissions'

/**
 * Retorna el rol efectiu de l'usuari en el context actual (tenant + site).
 *
 * Lògica de resolució (basada en JWT app_metadata.user_tenants):
 *
 *   1. Si no hi ha tenant seleccionat → null
 *   2. Si selectedSiteId és null (Vista Global) → global_role del tenant
 *   3. Si hi ha selectedSiteId:
 *      a. Agafa el rol del site específic (si existeix)
 *      b. Si l'usuari té global_role, compara amb el del site i retorna el més permissiu
 *         (l'owner global sempre té més permisos que un manager de site)
 *
 * Ordre de permisos: owner > manager > member > viewer
 *
 * Ús:
 *   const { role, isAtLeast, canWrite } = useActiveRole()
 *   if (!canWrite) return <ReadOnlyView />
 */

import type { Role } from '../lib/permissions'

const ROLE_WEIGHT: Record<Role, number> = ROLE_LEVELS

function mostPermissive(a: Role | null, b: Role | null): Role | null {
  if (!a) return b
  if (!b) return a
  return ROLE_WEIGHT[a] >= ROLE_WEIGHT[b] ? a : b
}

export function useActiveRole() {
  const { session } = useAuth()
  const { selectedTenantId, selectedSiteId } = useTenant()

  const userTenants = session?.user?.app_metadata?.user_tenants as
    | Record<string, { global_role: Role | null; sites: Record<string, Role> }>
    | undefined

  if (!selectedTenantId || !userTenants) {
    return { role: null, isAtLeast: () => false, canWrite: false }
  }

  const tenantClaims = userTenants[selectedTenantId]
  if (!tenantClaims) {
    return { role: null, isAtLeast: () => false, canWrite: false }
  }

  const globalRole = tenantClaims.global_role ?? null

  let role: Role | null
  if (selectedSiteId === null) {
    // Vista agregada: rol global si existeix; si no, el més permissiu dels sites assignats.
    if (globalRole) {
      role = globalRole
    } else {
      const siteRoles = Object.values(tenantClaims.sites ?? {}) as Role[]
      role = siteRoles.reduce<Role | null>((acc, current) => mostPermissive(acc, current), null)
    }
  } else {
    // Vista de site: el més permissiu entre el rol del site i el rol global
    const siteRole = (tenantClaims.sites?.[selectedSiteId] ?? null) as Role | null
    role = mostPermissive(globalRole, siteRole)
  }

  const isAtLeast = (minimum: Role): boolean => {
    if (!role) return false
    return ROLE_WEIGHT[role] >= ROLE_WEIGHT[minimum]
  }

  return {
    /** Rol efectiu en el context actual */
    role,
    /** true si el rol és >= el mínim requerit (ex: isAtLeast('member')) */
    isAtLeast,
    /** Drecera: pot crear/editar/eliminar (owner, manager, member) */
    canWrite: isAtLeast('member'),
    /** Drecera: pot gestionar membres i configuració (owner, manager) */
    canManage: isAtLeast('manager'),
    /** true si l'usuari té rol global al tenant (pot veure Vista Global) */
    hasGlobalRole: globalRole !== null,
  }
}
