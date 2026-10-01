/** Deep-links into `/documents/templates` for commercial full-body categories. */

export type CommercialTemplateHubCategory =
  | 'quote'
  | 'delivery_note'
  | 'commercial_agreement'

export function commercialTemplatesHref(
  category: CommercialTemplateHubCategory,
  opts?: { create?: boolean },
): string {
  const params = new URLSearchParams({ category })
  if (opts?.create) params.set('create', '1')
  return `/documents/templates?${params.toString()}`
}

export const QUOTE_TEMPLATES_HREF = commercialTemplatesHref('quote')
export const AGREEMENT_TEMPLATES_HREF = commercialTemplatesHref('commercial_agreement')
