import type { SigningRolesSchema, SigningRoleDef, VariablesSchema, VariableDef, VariableType } from '../../api/signingService'
import { ROLE_CATALOG_BY_KEY } from '../../constants/roleCatalog'
import type { AIRoleItem, AIVariableItem } from './schema'

export function mapAiVariableType(type: AIVariableItem['type']): VariableType {
  return type === 'text' ? 'string' : type
}

export function aiRolesToSchema(roles: AIRoleItem[]): SigningRolesSchema {
  const result: SigningRolesSchema = {}
  roles.forEach((r, idx) => {
    const catalog = ROLE_CATALOG_BY_KEY[r.key]
    const def: SigningRoleDef = {
      entity_type: r.entity_type ?? catalog?.entity_type ?? 'employee',
      label:       r.label,
      order:       r.order ?? idx + 1,
      for_signing: r.for_signing ?? catalog?.for_signing ?? true,
    }
    result[r.key] = def
  })
  return result
}

export function aiVariablesToSchema(variables: AIVariableItem[]): VariablesSchema | null {
  if (variables.length === 0) return null
  const result: VariablesSchema = {}
  variables.forEach((v, idx) => {
    const def: VariableDef = {
      type:     mapAiVariableType(v.type),
      label:    v.label,
      required: v.required ?? false,
      role:     v.role ?? undefined,
      order:    v.order ?? idx,
    }
    result[v.key] = def
  })
  return result
}

export function schemaToKeySets(
  variablesSchema: unknown,
  rolesSchema: unknown,
): { variableKeys: string[]; roleKeys: string[] } {
  const variableKeys = variablesSchema && typeof variablesSchema === 'object'
    ? Object.keys(variablesSchema as Record<string, unknown>)
    : []
  const roleKeys = rolesSchema && typeof rolesSchema === 'object'
    ? Object.keys(rolesSchema as Record<string, unknown>)
    : []
  return { variableKeys, roleKeys }
}

export function keysMatchSet(a: string[], b: string[]): boolean {
  const sa = new Set(a)
  const sb = new Set(b)
  if (sa.size !== sb.size) return false
  for (const k of sa) if (!sb.has(k)) return false
  return true
}
