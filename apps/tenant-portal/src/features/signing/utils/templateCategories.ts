import type { TFunction } from 'i18next'

export const COMMERCIAL_FULL_BODY_CATEGORIES = ['quote', 'delivery_note'] as const
export type CommercialFullBodyCategory = (typeof COMMERCIAL_FULL_BODY_CATEGORIES)[number]

export const DOCUMENT_TEMPLATE_CATEGORY_OPTIONS = [
  { value: 'quote', key: 'templates.kind.quote', fallback: 'Plantilla de pressupost', filterKey: 'templates.category.quote', filterFallback: 'Pressupost' },
  { value: 'delivery_note', key: 'templates.kind.delivery_note', fallback: "Plantilla d'albarà", filterKey: 'templates.category.delivery_note', filterFallback: 'Albarà' },
  { value: 'commercial', key: 'templates.category.commercial', fallback: 'Comercial' },
  { value: 'operations', key: 'templates.category.operations', fallback: 'Operacions' },
  { value: 'hr', key: 'templates.category.hr', fallback: 'RRHH' },
  { value: 'attendance', key: 'templates.category.attendance', fallback: 'Control horari' },
  { value: 'safety', key: 'templates.category.safety', fallback: 'PRL' },
  { value: 'legal', key: 'templates.category.legal', fallback: 'Legal' },
  { value: 'signing', key: 'templates.category.signing', fallback: 'Firma' },
] as const

export function isFullBodyTemplateCategory(
  category: string | null | undefined,
): category is CommercialFullBodyCategory {
  return category === 'quote' || category === 'delivery_note'
}

export function templateCategoryLabel(
  t: TFunction,
  category: string | null | undefined,
): string {
  if (!category) return ''
  const known = DOCUMENT_TEMPLATE_CATEGORY_OPTIONS.find((opt) => opt.value === category)
  if (!known) return category
  if ('filterKey' in known) return t(known.filterKey, known.filterFallback)
  return t(known.key, known.fallback)
}

export function templateKindLabel(
  t: TFunction,
  category: string | null | undefined,
): string {
  if (!category) return ''
  const known = DOCUMENT_TEMPLATE_CATEGORY_OPTIONS.find((opt) => opt.value === category)
  if (known) return t(known.key, known.fallback)
  return category
}
