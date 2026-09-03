import type { SigningRolesSchema, VariablesSchema } from '../../api/signingService'
import { ENTITY_FIELD_CATALOG } from '../../constants/entityFieldCatalog'

function dummyForField(field: string): string {
  const k = field.toLowerCase()
  if (k.includes('email') || k.includes('mail')) return 'exemple@empresa.cat'
  if (k.includes('phone') || k.includes('tel')) return '+34 600 000 000'
  if (k.includes('date') || k.endsWith('_on')) return '2026-01-15'
  if (k.includes('name') || k.includes('nom')) return 'Nom Exemple'
  if (k.includes('address') || k.includes('adrec')) return 'Carrer Exemple, 1'
  if (k.includes('city') || k.includes('ciutat')) return 'Barcelona'
  if (k.includes('id') || k.includes('nif') || k.includes('tax')) return '12345678A'
  if (k.includes('sku')) return 'SKU-001'
  if (k.includes('status') || k.includes('estat')) return 'actiu'
  if (k.includes('title') || k.includes('carrec') || k.includes('job')) return 'Tècnic/a'
  return 'Valor exemple'
}

export function generateDummyPreviewValues(
  variablesSchema: VariablesSchema | null,
  rolesSchema: SigningRolesSchema | null,
): Record<string, unknown> {
  const values: Record<string, unknown> = {
    today: new Date().toISOString().split('T')[0],
    date:  new Date().toISOString().split('T')[0],
    year:  String(new Date().getFullYear()),
    now:   new Date().toISOString(),
    globals: {
      today: new Date().toISOString().split('T')[0],
      date:  new Date().toISOString().split('T')[0],
      year:  String(new Date().getFullYear()),
      now:   new Date().toISOString(),
    },
    tenant: Object.fromEntries(
      (ENTITY_FIELD_CATALOG.tenant ?? []).map(f => [f.field, dummyForField(f.field)]),
    ),
    site: Object.fromEntries(
      (ENTITY_FIELD_CATALOG.site ?? []).map(f => [f.field, dummyForField(f.field)]),
    ),
    document_header: '',
    document_footer: '',
  }

  if (variablesSchema) {
    for (const [key, def] of Object.entries(variablesSchema)) {
      if (def.type === 'number') values[key] = 42000
      else if (def.type === 'date') values[key] = '2026-01-15'
      else values[key] = def.label ? `${def.label} (prova)` : dummyForField(key)
    }
  }

  if (rolesSchema) {
    for (const [roleKey, roleDef] of Object.entries(rolesSchema)) {
      const fields = ENTITY_FIELD_CATALOG[roleDef.entity_type] ?? ENTITY_FIELD_CATALOG.person
      const roleObj: Record<string, string> = {}
      for (const f of fields) {
        roleObj[f.field] = dummyForField(f.field)
      }
      values[roleKey] = roleObj
    }
  }

  return values
}
