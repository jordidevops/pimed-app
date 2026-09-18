import type { CommercialFullBodyCategory } from './templateCategories'

/** Equal visual size required by 01 §3 / §4 (validation does not check CSS). */
export const COMMERCIAL_SIGNATURE_BOX_STYLE = 'width:220px;height:70px;display:inline-block;'

export const COMMERCIAL_QUOTE_DOCX_SIGNATURE_TAGS = [
  '{{Accepto;type=signature;role=client_accept}}',
  '{{Refuso;type=signature;role=client_reject}}',
] as const

export const COMMERCIAL_DELIVERY_DOCX_SIGNATURE_TAG =
  '{{Conformitat;type=signature;role=client_delivery}}' as const

export function commercialQuoteAcceptRejectHtml(labels?: { accept?: string; reject?: string }): string {
  const accept = labels?.accept ?? 'Accepto'
  const reject = labels?.reject ?? 'Refuso'
  return `<div class="sigs">
  <div>
    <div>${accept}</div>
    <signature-field name="Accepto" role="client_accept" style="${COMMERCIAL_SIGNATURE_BOX_STYLE}"></signature-field>
  </div>
  <div>
    <div>${reject}</div>
    <signature-field name="Refuso" role="client_reject" style="${COMMERCIAL_SIGNATURE_BOX_STYLE}"></signature-field>
  </div>
</div>`
}

export function commercialDeliveryConformityHtml(label = 'Conformitat'): string {
  return `<div>
  <div>${label}</div>
  <signature-field name="Conformitat" role="client_delivery" style="${COMMERCIAL_SIGNATURE_BOX_STYLE}"></signature-field>
</div>`
}

export function commercialSignatureHtml(category: CommercialFullBodyCategory): string {
  return category === 'delivery_note'
    ? commercialDeliveryConformityHtml()
    : commercialQuoteAcceptRejectHtml()
}

const BOX_RE = /width:\s*220px[\s;][\s\S]{0,80}height:\s*70px|height:\s*70px[\s;][\s\S]{0,80}width:\s*220px/

export function htmlHasEqualCommercialSignatureBoxes(
  html: string,
  category: CommercialFullBodyCategory,
): boolean {
  const roles = category === 'delivery_note' ? ['client_delivery'] : ['client_accept', 'client_reject']
  return roles.every((role) => {
    const fieldRe = new RegExp(`<signature-field\\b[^>]*\\brole="${role}"[^>]*>`, 'i')
    const match = html.match(fieldRe)
    return Boolean(match && BOX_RE.test(match[0]))
  })
}

export function commercialSigningRolesToEnsure(category: CommercialFullBodyCategory): Array<{
  roleName: string
  entity_type: 'contact'
  label: string
  for_signing: true
}> {
  if (category === 'delivery_note') {
    return [{ roleName: 'client_delivery', entity_type: 'contact', label: 'Conformitat', for_signing: true }]
  }
  return [
    { roleName: 'client_accept', entity_type: 'contact', label: 'Accepto', for_signing: true },
    { roleName: 'client_reject', entity_type: 'contact', label: 'Refuso', for_signing: true },
  ]
}
