/** Camps d'entitat disponibles per a prompts IA i inserció a plantilles HTML. */
export const ENTITY_FIELD_CATALOG: Record<string, { field: string; label: string }[]> = {
  employee: [
    { field: 'full_name',   label: 'Nom complet' },
    { field: 'email',       label: 'Email' },
    { field: 'phone',       label: 'Telèfon' },
    /** Alias: resolt com a nom del lloc de treball (job_positions.name) per plantilles antigues */
    { field: 'job_title',   label: 'Lloc de treball' },
    { field: 'document_id', label: 'NIF/DNI' },
    { field: 'starts_on',   label: 'Data incorporació' },
    { field: 'status',      label: 'Estat' },
  ],
  contact: [
    { field: 'display_name', label: 'Nom' },
    { field: 'email',        label: 'Email' },
    { field: 'phone',        label: 'Telèfon' },
    { field: 'company_name', label: 'Empresa' },
  ],
  user: [
    { field: 'full_name', label: 'Nom complet' },
    { field: 'email',     label: 'Email' },
  ],
  site: [
    { field: 'name',    label: 'Nom seu' },
    { field: 'address', label: 'Adreça' },
    { field: 'city',    label: 'Ciutat' },
  ],
  tenant: [
    { field: 'name',     label: 'Nom empresa' },
    { field: 'slug',     label: 'Identificador' },
    { field: 'logo_url', label: 'Logo URL' },
    { field: 'address',  label: 'Adreça' },
    { field: 'phone',    label: 'Telèfon' },
    { field: 'email',    label: 'Email' },
    { field: 'website',  label: 'Web' },
    { field: 'tax_id',   label: 'CIF/NIF' },
  ],
  asset: [
    { field: 'name',          label: 'Nom actiu' },
    { field: 'serial_number', label: 'Número de sèrie' },
    { field: 'model',         label: 'Model' },
  ],
  person: [
    { field: 'full_name', label: 'Nom complet' },
    { field: 'email',     label: 'Email' },
  ],
  catalog_item: [
    { field: 'name', label: 'Nom' },
    { field: 'sku',  label: 'SKU' },
  ],
}

export const GLOBAL_TEMPLATE_VARIABLES = ['today', 'year', 'now', 'date'] as const

/** Prefixos resolts automàticament pel servidor — NO cal declarar-los a roles/variables del JSON. */
export const AUTO_INJECTED_CONTEXT_PREFIXES = [
  'tenant',
  'site',
  'globals',
  'document_header',
  'document_footer',
] as const

export function isAutoInjectedLiquidRef(ref: string): boolean {
  const prefix = ref.split('.')[0]
  if ((AUTO_INJECTED_CONTEXT_PREFIXES as readonly string[]).includes(prefix)) return true
  if (prefix.startsWith('custom_block_')) return true
  if ((GLOBAL_TEMPLATE_VARIABLES as readonly string[]).includes(ref)) return true
  return false
}
