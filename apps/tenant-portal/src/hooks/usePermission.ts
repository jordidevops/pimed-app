import { useAuth } from '../contexts/AuthContext'
import { useTenant } from '../contexts/TenantContext'
import {
  OWNER_WILDCARD,
  type JwtUserPermissions,
  type PermissionKey,
  type Role,
  computeRolePermissions,
  hasPermission,
} from '../lib/permissions'

// ---------------------------------------------------------------------------
// usePermission
// ---------------------------------------------------------------------------
//
// Comprova si l'usuari autenticat té un permís concret en el context actual.
//
// Lògica de resolució (basada en JWT app_metadata.user_permissions):
//
//   1. Si no hi ha tenant seleccionat o sessió → false
//   2. Si targetSiteId és undefined → usa selectedSiteId del context actiu
//   3. Si el context és global (siteId = null):
//        → comprova global_permissions del tenant
//   4. Si el context és de site:
//        → comprova global_permissions PRIMER (herència global → site)
//        → si no, comprova permissions del site concret
//   5. El wildcard '*' sempre retorna true (rol owner)
//
// Ús:
//   const canUpload = usePermission('storage.upload')
//   const canEditSite = usePermission('calendar.edit', 'site-uuid-123')
//   const canViewGlobal = usePermission('invoices.view', null)  // força context global
//
// Tipus:
//   La clau de permís és un TypeScript Union Type → autocompletat i validació en temps de compilació.
// ---------------------------------------------------------------------------

/**
 * Comprova si l'usuari té un permís concret en el context actual o en un site específic.
 *
 * @param permissionKey - Clau de permís a validar (ex: 'storage.upload', 'invoices.view')
 * @param targetSiteId - Context de site:
 *   - `undefined` → usa el site seleccionat al TenantContext (comportament per defecte)
 *   - `null`      → força context global (comprova només global_permissions)
 *   - `string`    → comprova permisos d'un site concret (+ herència global)
 * @returns `true` si l'usuari té el permís, `false` en cas contrari
 */
function roleFromTenantContext(
  activeRole: string | null | undefined,
  activeSiteRole: string | null | undefined,
  targetSiteId: string | null | undefined,
  selectedSiteId: string | null | undefined,
): Role | null {
  const siteToCheck = targetSiteId !== undefined ? targetSiteId : selectedSiteId
  const role =
    siteToCheck === null
      ? (activeRole ?? activeSiteRole)
      : siteToCheck
        ? (activeSiteRole ?? activeRole)
        : (activeRole ?? activeSiteRole)
  return (role as Role | null) ?? null
}

export function usePermission(
  permissionKey: PermissionKey,
  targetSiteId?: string | null,
): boolean {
  const { session } = useAuth()
  const { selectedTenantId, selectedSiteId, activeRole, activeSiteRole } = useTenant()

  if (!session || !selectedTenantId) return false

  const userPermissions = session.user?.app_metadata?.user_permissions as
    | JwtUserPermissions
    | undefined

  // ── Fallback: si no hi ha user_permissions (token antic / claim no sync a user),
  //    calcula des de user_tenants JWT o, si tampoc hi són, des del rol de TenantContext
  //    (mateix criteri que useCanManageEmployeePortal).
  if (!userPermissions) {
    const userTenants = session.user?.app_metadata?.user_tenants as
      | Record<string, { global_role?: string | null; sites?: Record<string, string> }>
      | undefined

    if (userTenants) {
      const tenantEntry = userTenants[selectedTenantId]
      if (tenantEntry) {
        const siteToCheck = targetSiteId !== undefined ? targetSiteId : selectedSiteId
        const role = (siteToCheck && tenantEntry.sites?.[siteToCheck]) || tenantEntry.global_role
        if (role) {
          return hasPermission(computeRolePermissions(role as Role), permissionKey)
        }
      }
    }

    const ctxRole = roleFromTenantContext(
      activeRole,
      activeSiteRole,
      targetSiteId,
      selectedSiteId,
    )
    if (!ctxRole) return false
    return hasPermission(computeRolePermissions(ctxRole), permissionKey)
  }

  const tenantPerms = userPermissions[selectedTenantId]
  if (!tenantPerms) return false

  const globalPerms = tenantPerms.global_permissions ?? []

  // Wildcard global (owner)
  if (globalPerms.length > 0 && globalPerms[0] === OWNER_WILDCARD) return true

  // Determina quin site comprovar:
  // - Si targetSiteId s'ha passat explícitament (fins i tot null), l'usa directament.
  // - Si no s'ha passat (undefined), usa el site del context actiu.
  const siteToCheck = targetSiteId !== undefined ? targetSiteId : selectedSiteId

  if (siteToCheck === null) {
    // Context global: comprova únicament global_permissions
    return (globalPerms as string[]).includes(permissionKey)
  }

  // Context de site: herència global + permisos del site concret
  if ((globalPerms as string[]).includes(permissionKey)) return true

  const sitePerms = tenantPerms.sites?.[siteToCheck]?.permissions ?? []

  // Wildcard de site (member/owner del site concret)
  if (sitePerms.length > 0 && sitePerms[0] === OWNER_WILDCARD) return true

  return (sitePerms as string[]).includes(permissionKey)
}

// ---------------------------------------------------------------------------
// usePermissions (plural) — comprova múltiples permisos alhora
// ---------------------------------------------------------------------------

/**
 * Comprova múltiples permisos alhora. Retorna un Record amb el resultat de cada un.
 *
 * Ús:
 *   const { 'storage.view': canView, 'storage.upload': canUpload } =
 *     usePermissions(['storage.view', 'storage.upload'])
 */
export function usePermissions<T extends PermissionKey>(
  permissionKeys: T[],
  targetSiteId?: string | null,
): Record<T, boolean> {
  const { session } = useAuth()
  const { selectedTenantId, selectedSiteId, activeRole, activeSiteRole } = useTenant()

  const falseAll = Object.fromEntries(permissionKeys.map((k) => [k, false])) as Record<T, boolean>

  if (!session || !selectedTenantId) return falseAll

  const userPermissions = session.user?.app_metadata?.user_permissions as
    | JwtUserPermissions
    | undefined

  if (!userPermissions) {
    const ctxRole = roleFromTenantContext(
      activeRole,
      activeSiteRole,
      targetSiteId,
      selectedSiteId,
    )
    if (!ctxRole) return falseAll
    const perms = computeRolePermissions(ctxRole)
    return Object.fromEntries(
      permissionKeys.map((k) => [k, hasPermission(perms, k)]),
    ) as Record<T, boolean>
  }

  const tenantPerms = userPermissions[selectedTenantId]
  if (!tenantPerms) return falseAll

  const globalPerms = tenantPerms.global_permissions ?? []
  const isGlobalWildcard = globalPerms.length > 0 && globalPerms[0] === OWNER_WILDCARD

  if (isGlobalWildcard) {
    return Object.fromEntries(permissionKeys.map((k) => [k, true])) as Record<T, boolean>
  }

  const siteToCheck = targetSiteId !== undefined ? targetSiteId : selectedSiteId
  const sitePerms = siteToCheck
    ? (tenantPerms.sites?.[siteToCheck]?.permissions ?? [])
    : []
  const isSiteWildcard = sitePerms.length > 0 && sitePerms[0] === OWNER_WILDCARD

  return Object.fromEntries(
    permissionKeys.map((k) => {
      if (siteToCheck === null) {
        return [k, (globalPerms as string[]).includes(k)]
      }
      const has =
        isSiteWildcard ||
        (globalPerms as string[]).includes(k) ||
        (sitePerms as string[]).includes(k)
      return [k, has]
    }),
  ) as Record<T, boolean>
}
