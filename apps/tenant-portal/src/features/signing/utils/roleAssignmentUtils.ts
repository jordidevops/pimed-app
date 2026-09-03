import type { SigningRoleDef } from '../api/signingService'

export interface RoleAssignment {
  roleName:     string
  email:        string
  name:         string
  entity_id?:   string
  entity_type?: string
  extra?:       Record<string, string>
  /** Tipus d'entitat per al cercador (pot diferir del definit a la plantilla). */
  pickerEntityType?: string
  /** entity = cercar a la BD; manual = introduir nom i correu. */
  inputMode?: 'entity' | 'manual'
}

export const FIXED_CONTEXT_ENTITY_TYPES = ['tenant', 'site', 'asset', 'catalog_item'] as const
export const CYCLABLE_PICKER_TYPES = ['employee', 'contact', 'person', 'user'] as const

export function isFixedContextType(entityType: string): boolean {
  return (FIXED_CONTEXT_ENTITY_TYPES as readonly string[]).includes(entityType)
}

export function canToggleInputMode(roleDef?: SigningRoleDef): boolean {
  const t = roleDef?.entity_type ?? 'person'
  return !isFixedContextType(t)
}

export function getDefaultPickerType(roleDef?: SigningRoleDef): string {
  const t = roleDef?.entity_type ?? 'person'
  if (t === 'user') return 'employee'
  if (isFixedContextType(t)) return t
  return t
}

export function getEffectivePickerType(ra: RoleAssignment, roleDef?: SigningRoleDef): string {
  if (ra.inputMode === 'manual') return 'user'
  return ra.pickerEntityType ?? getDefaultPickerType(roleDef)
}

export function createRoleAssignmentBase(
  roleName: string,
  roleDef: SigningRoleDef,
  activeTenantId?: string,
): RoleAssignment {
  const roleEntityType = roleDef.entity_type ?? 'person'
  const isFixed = isFixedContextType(roleEntityType)
  const isManualDefault = roleEntityType === 'user'

  return {
    roleName,
    email: roleEntityType === 'tenant' ? '__tenant__' : '',
    name: '',
    entity_id: roleEntityType === 'tenant' ? activeTenantId : undefined,
    entity_type: roleEntityType || undefined,
    pickerEntityType: isFixed ? roleEntityType : (isManualDefault ? 'employee' : roleEntityType),
    inputMode: isFixed ? 'entity' : (isManualDefault ? 'manual' : 'entity'),
  }
}

export function cyclePickerType(current: string): Pick<RoleAssignment, 'pickerEntityType' | 'inputMode'> {
  const cycle = CYCLABLE_PICKER_TYPES
  const idx = Math.max(0, cycle.indexOf(current as (typeof cycle)[number]))
  const next = cycle[(idx + 1) % cycle.length]
  if (next === 'user') {
    return { pickerEntityType: 'employee', inputMode: 'manual' }
  }
  return { pickerEntityType: next, inputMode: 'entity' }
}

export function clearedAssignmentFields(): Pick<RoleAssignment, 'name' | 'email' | 'entity_id' | 'entity_type' | 'extra'> {
  return { name: '', email: '', entity_id: undefined, entity_type: undefined, extra: undefined }
}

export function initRoleAssignmentsFromSchema(
  rolesSchema: Record<string, import('../api/signingService').SigningRoleDef>,
  activeTenantId?: string,
): RoleAssignment[] {
  return Object.entries(rolesSchema)
    .sort(([, a], [, b]) => a.order - b.order)
    .map(([roleName, roleDef]) => createRoleAssignmentBase(roleName, roleDef, activeTenantId))
}
