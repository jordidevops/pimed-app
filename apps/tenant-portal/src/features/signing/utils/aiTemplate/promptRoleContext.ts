import type { TenantRoleDefault } from '../../api/useTenantRoleDefaults'
import { buildPriorityDefaultsMap } from '../../api/useTenantRoleDefaults'
import {
  ROLE_CATALOG,
  ROLE_CATALOG_BY_KEY,
  CONTEXT_AUTO_ROLE_KEYS,
  type CatalogRole,
} from '../../constants/roleCatalog'

export interface PromptRoleDescriptor {
  key: string
  entity_type: string
  for_signing: boolean
  label: string
  tier: 'configured' | 'context_auto' | 'catalog'
  defaultEntityLabel?: string | null
  defaultEntityEmail?: string | null
}

export interface ResolvedPromptRoles {
  configured: PromptRoleDescriptor[]
  contextAuto: PromptRoleDescriptor[]
  catalogRest: PromptRoleDescriptor[]
}

function pickCatalogLabel(role: CatalogRole, locale: string): string {
  const labels = role.labels as Record<string, string>
  return labels[locale] ?? labels.ca ?? role.key
}

function toDescriptor(
  roleKey: string,
  entityType: string,
  targetLocale: string,
  tier: PromptRoleDescriptor['tier'],
  defaultRow?: TenantRoleDefault,
): PromptRoleDescriptor {
  const catalog = ROLE_CATALOG_BY_KEY[roleKey]
  return {
    key: roleKey,
    entity_type: entityType,
    for_signing: catalog?.for_signing ?? true,
    label: catalog ? pickCatalogLabel(catalog, targetLocale) : roleKey,
    tier,
    defaultEntityLabel: defaultRow?.entity_label,
    defaultEntityEmail: defaultRow?.entity_email,
  }
}

export function resolvePromptRoles(
  defaults: TenantRoleDefault[],
  siteId: string | null | undefined,
  targetLocale: string,
): ResolvedPromptRoles {
  const priorityMap = buildPriorityDefaultsMap(defaults, siteId)
  const configuredKeys = new Set<string>()
  const configured: PromptRoleDescriptor[] = []

  for (const row of Object.values(priorityMap)) {
    if (!row.role_key || configuredKeys.has(row.role_key)) continue
    configuredKeys.add(row.role_key)
    configured.push(toDescriptor(
      row.role_key,
      row.entity_type ?? ROLE_CATALOG_BY_KEY[row.role_key]?.entity_type ?? 'employee',
      targetLocale,
      'configured',
      row,
    ))
  }
  configured.sort((a, b) => a.key.localeCompare(b.key))

  const contextAuto: PromptRoleDescriptor[] = []
  const catalogRest: PromptRoleDescriptor[] = []

  for (const role of ROLE_CATALOG) {
    if (configuredKeys.has(role.key)) continue
    const descriptor = toDescriptor(role.key, role.entity_type, targetLocale, 'catalog')
    if (CONTEXT_AUTO_ROLE_KEYS.has(role.key)) {
      contextAuto.push({ ...descriptor, tier: 'context_auto' })
    } else {
      catalogRest.push(descriptor)
    }
  }

  return { configured, contextAuto, catalogRest }
}

export function rolesForPathVariables(roles: ResolvedPromptRoles): PromptRoleDescriptor[] {
  const out: PromptRoleDescriptor[] = [...roles.configured, ...roles.contextAuto]
  const coveredEntityTypes = new Set(out.map(r => r.entity_type))

  for (const role of roles.catalogRest) {
    if (coveredEntityTypes.has(role.entity_type)) continue
    out.push(role)
    coveredEntityTypes.add(role.entity_type)
  }

  return out
}

export function exampleRoleKeys(roles: ResolvedPromptRoles): [string, string] {
  const first = roles.configured[0]?.key
    ?? roles.contextAuto[0]?.key
    ?? 'worker'
  const second = roles.configured.find(r => r.key !== first)?.key
    ?? roles.contextAuto.find(r => r.key !== first)?.key
    ?? roles.catalogRest.find(r => r.key !== first)?.key
    ?? 'manager'
  return [first, second]
}
