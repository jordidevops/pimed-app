export const TERM_KEYS = [
  'project',
  'project_plural',
  'contact',
  'contacts',
  'price_sheet',
] as const

export type TermKey = (typeof TERM_KEYS)[number]

export const TERM_MIN_LEN = 2
export const TERM_MAX_LEN = 40

/** Folded exact-match denylist: Pressupost / Albarà / Factura (ca/es). */
export const TERM_DENIED_FOLDED = new Set([
  'pressupost',
  'pressupostos',
  'presupuesto',
  'presupuestos',
  'albara',
  'albaran',
  'albarans',
  'albaranes',
  'factura',
  'facturas',
])

const LATIN_ACCENTS = 'àáâäãåèéêëìíîïòóôöõùúûüçñýÿ·'

export function isTermKey(key: string): key is TermKey {
  return (TERM_KEYS as readonly string[]).includes(key)
}

export function foldTermValue(value: string): string {
  const lower = value.toLowerCase()
  let out = ''
  for (const ch of lower) {
    const idx = LATIN_ACCENTS.indexOf(ch)
    out += idx === -1 ? ch : 'aaaaaaeeeeiiiiooooouuuucnyy '[idx] ?? ch
  }
  return out
}

export function termBadges(key: TermKey, archetype: string | null | undefined): string[] {
  const arch = archetype ?? 'generic'
  if (key === 'price_sheet') {
    return ['Imports', 'Què es cobra', 'Partides']
  }
  if (key === 'project') {
    if (arch === 'field_service') return ['Obra', 'Ordre de servei']
    if (arch === 'practice') return ['Expedient']
    if (arch === 'hospitality') return ['Reserva']
    if (arch === 'workshop_maker') return ['Comanda']
    return ['Projecte']
  }
  if (key === 'project_plural') {
    if (arch === 'field_service') return ['Obres', 'Ordres de servei']
    if (arch === 'practice') return ['Expedients']
    if (arch === 'hospitality') return ['Reserves']
    if (arch === 'workshop_maker') return ['Comandes']
    return ['Projectes']
  }
  if (key === 'contact') {
    if (arch === 'hospitality') return ['Hoste']
    return ['Client']
  }
  if (arch === 'hospitality') return ['Hostes']
  return ['Clients']
}
