// =============================================================================
// RBAC — Permisos, Jerarquies i Funcions d'Herència
// =============================================================================
//
// ARQUITECTURA:
//   - 4 rols jeràrquics: owner (4) > manager (3) > member (2) > viewer (1)
//   - Herència acumulativa: cada rol superior hereta tots els permisos dels inferiors.
//   - Personalització per tenant: el tenant pot substituir els permisos BASE de
//     manager/member/viewer (no owner). L'herència segueix aplicant-se.
//   - Dependències: alguns permisos requereixen altres (ex: edit → view).
//
// PERSISTÈNCIA:
//   - Personalitzacions guardades a data.tenants.metadata->'role_permissions'
//   - Estructura: { "manager": ["perm.1"], "member": ["perm.1", "perm.2"] }
//
// JWT (app_metadata.user_permissions):
//   {
//     "<tenant_id>": {
//       "global_permissions": ["storage.view", ...] | ["*"],
//       "sites": {
//         "<site_id>": { "permissions": ["storage.view", ...] | ["*"] }
//       }
//     }
//   }
// =============================================================================

// ---------------------------------------------------------------------------
// Tipus base
// ---------------------------------------------------------------------------

export type Role = 'owner' | 'manager' | 'member' | 'viewer'

export const ROLE_LEVELS: Record<Role, number> = {
  owner:   4,
  manager: 3,
  member:  2,
  viewer:  1,
}

export const OWNER_WILDCARD = '*' as const
export type OwnerWildcard = typeof OWNER_WILDCARD

// ---------------------------------------------------------------------------
// Claus de permisos (Union Type — garanteix autocompletat i validació estàtica)
// ---------------------------------------------------------------------------

export type PermissionKey =
  // Emmagatzematge
  | 'storage.view'
  | 'storage.upload'
  | 'storage.delete'
  | 'storage.manage'
  // Calendari
  | 'calendar.view'
  | 'calendar.edit'
  | 'calendar.manage'
  // Email
  | 'email.view'
  | 'email.send'
  | 'email.manage'
  // Facturació
  | 'invoices.view'
  | 'invoices.edit'
  | 'invoices.manage'
  // Membres
  | 'members.view'
  | 'members.invite'
  | 'members.manage'
  // Sites
  | 'sites.view'
  | 'sites.create'
  | 'sites.manage'
  // Configuració
  | 'settings.view'
  | 'settings.manage'
  // Gestió de permisos (RBAC)
  | 'permissions.manage'
  // IA
  | 'ai.use'
  | 'ai.configure'
  | 'ai.tools.write'
  // Empleats / HR (EHR-0)
  | 'employees.directory.view'
  | 'employees.view'
  | 'employees.manage'
  | 'employees.private.view'
  | 'employees.private.manage'
  | 'employees.private.reveal'
  | 'employees.skills.manage'
  | 'employees.lifecycle.view'
  | 'employees.lifecycle.manage'
  | 'employees.contracts.view'
  | 'employees.contracts.manage'
  | 'employees.contracts.approve'
  | 'employees.compensation.view'
  | 'employees.compensation.edit'
  // Compliment (CR-0+)
  | 'compliance.requirements.manage'
  | 'compliance.certifications.view'
  | 'compliance.certifications.manage'
  | 'compliance.medical_clearance.view'
  | 'compliance.medical_clearance.manage'
  // Actius (EA-0+)
  | 'assets.view'
  | 'assets.manage'
  | 'assets.employee_assignments.view'
  | 'assets.employee_assignments.manage'
  // Reclutament / ATS (REC-1)
  | 'recruitment.view'
  | 'recruitment.manage'
  | 'recruitment.interview'
  | 'recruitment.rights'
  // Field service / butlletí client (CP-A1)
  | 'field_service.reports.publish'
  | 'field_service.reports.regenerate'
  | 'field_service.reports.share'
  | 'field_service.reports.revoke'
  | 'field_service.reports.preview_as_customer'
  | 'contacts.portal.manage'
  // Flux comercial (CF-1 / CF-13)
  | 'commercial.pricing.edit'
  // Control horari i absències
  | 'attendance.punch_own'
  | 'attendance.approve'
  | 'absences.request'

/** Totes les claus com a array (útil per validació runtime) */
export const ALL_PERMISSION_KEYS: PermissionKey[] = [
  'storage.view', 'storage.upload', 'storage.delete', 'storage.manage',
  'calendar.view', 'calendar.edit', 'calendar.manage',
  'email.view', 'email.send', 'email.manage',
  'invoices.view', 'invoices.edit', 'invoices.manage',
  'members.view', 'members.invite', 'members.manage',
  'sites.view', 'sites.create', 'sites.manage',
  'settings.view', 'settings.manage',
  'permissions.manage',
  'ai.use', 'ai.configure', 'ai.tools.write',
  'employees.directory.view', 'employees.view', 'employees.manage',
  'employees.private.view', 'employees.private.manage', 'employees.private.reveal', 'employees.skills.manage',
  'employees.lifecycle.view', 'employees.lifecycle.manage',
  'employees.contracts.view', 'employees.contracts.manage', 'employees.contracts.approve',
  'employees.compensation.view', 'employees.compensation.edit',
  'compliance.requirements.manage',
  'compliance.certifications.view', 'compliance.certifications.manage',
  'compliance.medical_clearance.view', 'compliance.medical_clearance.manage',
  'assets.view', 'assets.manage',
  'assets.employee_assignments.view', 'assets.employee_assignments.manage',
  'recruitment.view', 'recruitment.manage', 'recruitment.interview', 'recruitment.rights',
  'field_service.reports.publish', 'field_service.reports.regenerate',
  'field_service.reports.share', 'field_service.reports.revoke',
  'field_service.reports.preview_as_customer',
  'contacts.portal.manage',
  'commercial.pricing.edit',
  'attendance.punch_own', 'attendance.approve', 'absences.request',
]

// ---------------------------------------------------------------------------
// Dependències de permisos
// Clau → array de permisos requerits PRÈVIAMENT.
// La resolució és recursiva (resolveDependencies garanteix la transitivitat).
// ---------------------------------------------------------------------------

export const PERMISSION_DEPENDENCIES: Partial<Record<PermissionKey, PermissionKey[]>> = {
  'storage.upload':     ['storage.view'],
  'storage.delete':     ['storage.view'],
  'storage.manage':     ['storage.view', 'storage.delete'],
  'calendar.edit':      ['calendar.view'],
  'calendar.manage':    ['calendar.view', 'calendar.edit'],
  'email.send':         ['email.view'],
  'email.manage':       ['email.view', 'email.send'],
  'invoices.edit':      ['invoices.view'],
  'invoices.manage':    ['invoices.view', 'invoices.edit'],
  'members.invite':     ['members.view'],
  'members.manage':     ['members.view', 'members.invite'],
  'sites.create':       ['sites.view'],
  'sites.manage':       ['sites.view', 'sites.create'],
  'settings.manage':    ['settings.view'],
  'permissions.manage': ['settings.view', 'settings.manage'],
  'employees.manage':           ['employees.view'],
  'employees.view':             ['employees.directory.view'],
  'employees.private.manage':   ['employees.private.view', 'employees.manage'],
  'employees.private.reveal':   ['employees.private.view'],
  'employees.private.view':     ['employees.view'],
  'employees.skills.manage':    ['employees.view'],
  'employees.lifecycle.manage': ['employees.lifecycle.view', 'employees.manage'],
  'employees.lifecycle.view':   ['employees.view'],
  'employees.contracts.view':   ['employees.view'],
  'employees.contracts.manage': ['employees.contracts.view', 'employees.manage'],
  'employees.contracts.approve': ['employees.contracts.view'],
  'employees.compensation.view': ['employees.contracts.view'],
  'employees.compensation.edit': ['employees.compensation.view'],
  'compliance.requirements.manage': ['employees.view'],
  'compliance.certifications.manage': ['compliance.certifications.view'],
  'compliance.medical_clearance.manage': ['compliance.medical_clearance.view'],
  'assets.manage': ['assets.view'],
  'assets.employee_assignments.view': ['assets.view'],
  'assets.employee_assignments.manage': ['assets.employee_assignments.view'],
  'recruitment.manage': ['recruitment.view'],
  'recruitment.interview': ['recruitment.view'],
  'recruitment.rights': ['recruitment.view'],
  'field_service.reports.regenerate': ['field_service.reports.publish'],
  'field_service.reports.share': ['field_service.reports.publish'],
  'field_service.reports.revoke': ['field_service.reports.share'],
  'field_service.reports.preview_as_customer': ['field_service.reports.publish'],
  'contacts.portal.manage': ['settings.view'],
}

// ---------------------------------------------------------------------------
// Permisos BASE per rol (sense herència ni dependències resoltes)
// Representa els permisos NOUS que aporta cada rol sobre l'anterior.
// L'owner no té llista: sempre retorna el wildcard '*'.
// ---------------------------------------------------------------------------

export const BASE_ROLE_PERMISSIONS: Record<Exclude<Role, 'owner'>, PermissionKey[]> = {
  viewer: [
    'storage.view',
    'calendar.view',
    'email.view',
    'invoices.view',
    'members.view',
    'sites.view',
    'settings.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view',
  ],
  member: [
    'storage.upload',
    'calendar.edit',
    'email.send',
    'invoices.edit',
    'ai.use',
    'employees.directory.view',
    'employees.view',
    'assets.view',
    'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'attendance.punch_own',
    'absences.request',
  ],
  manager: [
    'storage.delete',
    'calendar.manage',
    'email.manage',
    'invoices.manage',
    'members.invite',
    'sites.create',
    'settings.manage',
    'permissions.manage',
    'ai.configure',
    'ai.tools.write',
    'employees.directory.view',
    'employees.view',
    'employees.manage',
    'employees.private.view',
    'employees.private.manage',
    'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view',
    'employees.lifecycle.manage',
    'employees.contracts.view',
    'employees.contracts.manage',
    // compensation.* NO: només owner / concessió explícita
    'compliance.requirements.manage',
    'compliance.certifications.view',
    'compliance.certifications.manage',
    // medical_clearance.* NO: CR-D9 — concessió explícita (owner via *)
    'assets.view',
    'assets.manage',
    'assets.employee_assignments.view',
    'assets.employee_assignments.manage',
    'recruitment.view',
    'recruitment.manage',
    'recruitment.interview',
    // recruitment.rights NO: owner / concessió explícita
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage',
    'commercial.pricing.edit',
    'attendance.approve',
  ],
}

// Personalització del tenant (el que es guarda a metadata->'role_permissions')
export type TenantRoleCustomization = Partial<Record<Exclude<Role, 'owner'>, PermissionKey[]>>

// ---------------------------------------------------------------------------
// Funcions pures
// ---------------------------------------------------------------------------

/**
 * Normalitza una llista de permisos afegint recursivament totes les dependències.
 * Exemple: ['storage.upload'] → ['storage.upload', 'storage.view']
 */
export function resolveDependencies(permissions: PermissionKey[]): PermissionKey[] {
  const result = new Set<PermissionKey>(permissions)
  let changed = true
  while (changed) {
    changed = false
    for (const perm of [...result]) {
      const deps = PERMISSION_DEPENDENCIES[perm]
      if (deps) {
        for (const dep of deps) {
          if (!result.has(dep)) {
            result.add(dep)
            changed = true
          }
        }
      }
    }
  }
  return [...result]
}

/**
 * Calcula els permisos TOTALS d'un rol aplicant:
 *   1. Herència acumulativa (inclou tots els rols de nivell inferior)
 *   2. Personalitzacions del tenant (si s'especifiquen, SUBSTITUEIXEN els permisos BASE)
 *   3. Resolució de dependències
 *
 * @param role - Rol a calcular
 * @param customPermissions - Personalitzacions del tenant (opcional).
 *   Si es passa `{ "member": ["X"] }`, el membre base serà `["X"]` en lloc de `BASE_ROLE_PERMISSIONS.member`.
 *   L'herència dels rols inferiors segueix aplicant-se normalment.
 * @returns `['*']` per owner, o array de PermissionKey per la resta
 */
export function computeRolePermissions(
  role: Role,
  customPermissions?: TenantRoleCustomization,
): PermissionKey[] | [OwnerWildcard] {
  if (role === 'owner') return [OWNER_WILDCARD]

  const accumulated = new Set<PermissionKey>()

  // Acumula des de viewer fins al rol actual (herència acumulativa)
  const rolesToInclude: Array<Exclude<Role, 'owner'>> = ['viewer']
  if (ROLE_LEVELS[role] >= ROLE_LEVELS['member'])  rolesToInclude.push('member')
  if (ROLE_LEVELS[role] >= ROLE_LEVELS['manager']) rolesToInclude.push('manager')

  for (const r of rolesToInclude) {
    const base = customPermissions?.[r] ?? BASE_ROLE_PERMISSIONS[r]
    for (const perm of base) {
      accumulated.add(perm)
    }
  }

  return resolveDependencies([...accumulated])
}

/**
 * Comprova si un array de permisos (o wildcard) conté un permís concret.
 * Funció pura per ús fora de React (tests, server actions, etc.).
 */
export function hasPermission(
  permissions: PermissionKey[] | [OwnerWildcard],
  key: PermissionKey,
): boolean {
  if (permissions.length > 0 && permissions[0] === OWNER_WILDCARD) return true
  return (permissions as PermissionKey[]).includes(key)
}

/**
 * Valida que una personalització de permisos del tenant sigui coherent:
 *   - Només inclou claus de permís vàlides
 *   - No inclou rols no personalitzables (owner)
 * Llança un error si la validació falla.
 */
export function validateTenantCustomization(customization: unknown): TenantRoleCustomization {
  if (typeof customization !== 'object' || customization === null) {
    throw new Error('La personalització ha de ser un objecte')
  }

  const validRoles = new Set<string>(['manager', 'member', 'viewer'])
  const validPerms = new Set<string>(ALL_PERMISSION_KEYS)
  const result: TenantRoleCustomization = {}

  for (const [roleKey, perms] of Object.entries(customization as Record<string, unknown>)) {
    if (!validRoles.has(roleKey)) {
      throw new Error(`Rol no personalitzable: '${roleKey}'`)
    }
    if (!Array.isArray(perms)) {
      throw new Error(`Els permisos del rol '${roleKey}' han de ser un array`)
    }
    for (const p of perms) {
      if (typeof p !== 'string' || !validPerms.has(p)) {
        throw new Error(`Permís no vàlid: '${p}'`)
      }
    }
    result[roleKey as Exclude<Role, 'owner'>] = perms as PermissionKey[]
  }

  return result
}

// ---------------------------------------------------------------------------
// Tipus del JWT (app_metadata.user_permissions)
// ---------------------------------------------------------------------------

export type JwtSitePermissions = {
  permissions: PermissionKey[] | [OwnerWildcard]
}

export type JwtTenantPermissions = {
  global_permissions: PermissionKey[] | [OwnerWildcard]
  sites: Record<string, JwtSitePermissions>
}

export type JwtUserPermissions = Record<string, JwtTenantPermissions>
